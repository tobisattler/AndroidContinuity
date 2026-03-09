package com.androidcontinuity

import com.androidcontinuity.data.remote.GrpcChannelProvider
import com.androidcontinuity.discovery.DiscoveredDevice
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Test

class GrpcChannelProviderTest {

    private val provider = GrpcChannelProvider()

    @After
    fun tearDown() {
        provider.shutdownAll()
    }

    @Test
    fun `channelFor returns a ManagedChannel`() {
        val device = DiscoveredDevice(
            name = "Test Mac",
            host = "192.168.1.100",
            grpcPort = 50051,
            serviceName = "test-mac",
        )
        val channel = provider.channelFor(device)
        assertNotNull(channel)
    }

    @Test
    fun `channelFor caches channels by service name`() {
        val device = DiscoveredDevice(
            name = "Test Mac",
            host = "192.168.1.100",
            grpcPort = 50051,
            serviceName = "test-mac",
        )
        val channel1 = provider.channelFor(device)
        val channel2 = provider.channelFor(device)
        assertSame(channel1, channel2)
    }

    @Test
    fun `channelFor creates new channel for different devices`() {
        val device1 = DiscoveredDevice(
            name = "Mac 1",
            host = "192.168.1.100",
            grpcPort = 50051,
            serviceName = "mac-1",
        )
        val device2 = DiscoveredDevice(
            name = "Mac 2",
            host = "192.168.1.101",
            grpcPort = 50051,
            serviceName = "mac-2",
        )
        val channel1 = provider.channelFor(device1)
        val channel2 = provider.channelFor(device2)
        assertNotNull(channel1)
        assertNotNull(channel2)
        // Different service names → different channels
        assert(channel1 !== channel2)
    }
}
