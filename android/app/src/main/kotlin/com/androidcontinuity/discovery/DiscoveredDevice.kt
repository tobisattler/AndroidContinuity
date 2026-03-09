package com.androidcontinuity.discovery

/**
 * Represents a Mac discovered via mDNS/Bonjour on the local network.
 *
 * @property name     Human-readable device name from the Bonjour service.
 * @property host     Resolved IP address or hostname.
 * @property grpcPort The gRPC port advertised in the TXT record.
 * @property protoMajor Protocol major version from TXT record.
 * @property protoMinor Protocol minor version from TXT record.
 * @property deviceName Device name from TXT record (may differ from Bonjour service name).
 * @property serviceName The raw Bonjour service name (used as a stable identity key).
 */
data class DiscoveredDevice(
    val name: String,
    val host: String,
    val grpcPort: Int,
    val protoMajor: Int = 1,
    val protoMinor: Int = 0,
    val deviceName: String = name,
    val serviceName: String = name,
)
