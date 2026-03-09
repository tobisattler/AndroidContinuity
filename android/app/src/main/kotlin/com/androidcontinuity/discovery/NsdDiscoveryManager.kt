package com.androidcontinuity.discovery

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Discovers AndroidContinuity macOS hosts on the local network via mDNS (NSD).
 *
 * Wraps Android's [NsdManager] with a Kotlin [Flow]-based API. The [devices]
 * StateFlow always reflects the current set of discovered, resolved Macs.
 *
 * Usage:
 * ```
 * discoveryManager.startDiscovery()
 * discoveryManager.devices.collect { list -> /* update UI */ }
 * discoveryManager.stopDiscovery()
 * ```
 */
@Singleton
class NsdDiscoveryManager @Inject constructor(
    private val nsdManager: NsdManager,
) {
    companion object {
        private const val TAG = "NsdDiscovery"
        const val SERVICE_TYPE = "_androidcontinuity._tcp."
    }

    /** Current set of discovered & resolved devices. */
    private val _devices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val devices: StateFlow<List<DiscoveredDevice>> = _devices.asStateFlow()

    /** Whether discovery is currently active. */
    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // Track pending resolves to avoid duplicate resolution attempts
    private val pendingResolves = mutableSetOf<String>()

    // ──────────────────────────────────────────────────────────────
    // Public API
    // ──────────────────────────────────────────────────────────────

    /**
     * Start mDNS discovery for AndroidContinuity services.
     * Safe to call multiple times — subsequent calls are no-ops.
     */
    fun startDiscovery() {
        if (discoveryListener != null) {
            Log.d(TAG, "Discovery already active, ignoring startDiscovery()")
            return
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "Discovery started for $serviceType")
                _isDiscovering.value = true
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "Discovery stopped for $serviceType")
                _isDiscovering.value = false
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${serviceInfo.serviceName} (${serviceInfo.serviceType})")
                resolveService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
                _devices.update { list ->
                    list.filterNot { it.serviceName == serviceInfo.serviceName }
                }
                pendingResolves.remove(serviceInfo.serviceName)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: errorCode=$errorCode")
                _isDiscovering.value = false
                discoveryListener = null
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: errorCode=$errorCode")
            }
        }

        discoveryListener = listener
        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    /**
     * Stop mDNS discovery. Clears the discovered device list.
     */
    fun stopDiscovery() {
        discoveryListener?.let { listener ->
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "stopServiceDiscovery failed (already stopped?): ${e.message}")
            }
        }
        discoveryListener = null
        _isDiscovering.value = false
        _devices.value = emptyList()
        pendingResolves.clear()
    }

    // ──────────────────────────────────────────────────────────────
    // Cold Flow variant (auto start/stop)
    // ──────────────────────────────────────────────────────────────

    /**
     * Returns a cold [Flow] that starts discovery on collection and stops
     * when the collector cancels. Useful for lifecycle-scoped collection
     * in ViewModels.
     */
    fun discoverDevices(): Flow<List<DiscoveredDevice>> = callbackFlow {
        startDiscovery()

        // Forward device updates to the flow
        val job = launch {
            _devices.collect { send(it) }
        }

        awaitClose {
            job.cancel()
            stopDiscovery()
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Private
    // ──────────────────────────────────────────────────────────────

    @Suppress("DEPRECATION") // resolveService(NsdServiceInfo, ResolveListener) — replacement requires API 34
    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val serviceName = serviceInfo.serviceName
        if (serviceName in pendingResolves) {
            Log.d(TAG, "Already resolving $serviceName, skipping")
            return
        }
        pendingResolves.add(serviceName)

        nsdManager.resolveService(
            serviceInfo,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(si: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "Resolve failed for ${si.serviceName}: errorCode=$errorCode")
                    pendingResolves.remove(serviceName)
                }

                override fun onServiceResolved(si: NsdServiceInfo) {
                    pendingResolves.remove(serviceName)

                    @Suppress("DEPRECATION") // host property — replacement requires API 34
                    val host = si.host?.hostAddress
                    if (host == null) {
                        Log.w(TAG, "Resolved ${si.serviceName} but host is null")
                        return
                    }

                    val txtMap = parseTxtRecords(si)
                    val grpcPort = txtMap["grpc_port"]?.toIntOrNull() ?: si.port
                    val protoMajor = txtMap["proto_major"]?.toIntOrNull() ?: 1
                    val protoMinor = txtMap["proto_minor"]?.toIntOrNull() ?: 0
                    val deviceName = txtMap["device_name"] ?: si.serviceName

                    val device = DiscoveredDevice(
                        name = deviceName,
                        host = host,
                        grpcPort = grpcPort,
                        protoMajor = protoMajor,
                        protoMinor = protoMinor,
                        deviceName = deviceName,
                        serviceName = si.serviceName,
                    )

                    Log.i(TAG, "Resolved: $device")

                    _devices.update { list ->
                        // Replace existing entry or add new one
                        val filtered = list.filterNot { it.serviceName == si.serviceName }
                        filtered + device
                    }
                }
            },
        )
    }

    /**
     * Parse TXT records from [NsdServiceInfo.attributes].
     * The attributes map contains key-value pairs from the Bonjour TXT record.
     */
    private fun parseTxtRecords(serviceInfo: NsdServiceInfo): Map<String, String> {
        return serviceInfo.attributes.mapValues { (_, value) ->
            value?.let { String(it, Charsets.UTF_8) } ?: ""
        }
    }
}
