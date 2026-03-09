package com.androidcontinuity.data.remote

import com.androidcontinuity.discovery.DiscoveredDevice
import io.grpc.ManagedChannel
import io.grpc.ManagedChannelBuilder
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Provides gRPC [ManagedChannel] instances for communicating with discovered Macs.
 *
 * Caches channels by device service name and reuses them if the host/port haven't changed.
 * In Phase 4, channels use plaintext (no TLS). TLS will be added when the security
 * layer matures.
 */
@Singleton
class GrpcChannelProvider @Inject constructor() {

    private val channels = mutableMapOf<String, CachedChannel>()

    /**
     * Returns a [ManagedChannel] for the given device.
     * Reuses an existing channel if host/port match.
     */
    fun channelFor(device: DiscoveredDevice): ManagedChannel {
        val cached = channels[device.serviceName]
        if (cached != null && cached.host == device.host && cached.port == device.grpcPort) {
            return cached.channel
        }

        // Shut down old channel if it exists
        cached?.channel?.let { shutdownQuietly(it) }

        val channel = ManagedChannelBuilder
            .forAddress(device.host, device.grpcPort)
            .usePlaintext()
            .keepAliveTime(30, TimeUnit.SECONDS)
            .build()

        channels[device.serviceName] = CachedChannel(
            channel = channel,
            host = device.host,
            port = device.grpcPort,
        )

        return channel
    }

    /**
     * Shuts down all cached channels. Call when the app is done transferring.
     */
    fun shutdownAll() {
        channels.values.forEach { shutdownQuietly(it.channel) }
        channels.clear()
    }

    private fun shutdownQuietly(channel: ManagedChannel) {
        try {
            channel.shutdown().awaitTermination(3, TimeUnit.SECONDS)
        } catch (_: Exception) {
            channel.shutdownNow()
        }
    }

    private data class CachedChannel(
        val channel: ManagedChannel,
        val host: String,
        val port: Int,
    )
}
