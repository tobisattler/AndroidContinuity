package com.androidcontinuity

import com.androidcontinuity.discovery.DiscoveredDevice
import org.junit.Assert.assertEquals
import org.junit.Test

class DiscoveredDeviceTest {

    @Test
    fun `default values are set correctly`() {
        val device = DiscoveredDevice(
            name = "My Mac",
            host = "192.168.1.50",
            grpcPort = 50051,
        )
        assertEquals("My Mac", device.name)
        assertEquals("192.168.1.50", device.host)
        assertEquals(50051, device.grpcPort)
        assertEquals(1, device.protoMajor)
        assertEquals(0, device.protoMinor)
        assertEquals("My Mac", device.deviceName)
        assertEquals("My Mac", device.serviceName)
    }

    @Test
    fun `custom values override defaults`() {
        val device = DiscoveredDevice(
            name = "My Mac",
            host = "10.0.0.1",
            grpcPort = 8080,
            protoMajor = 2,
            protoMinor = 1,
            deviceName = "MacBook Pro",
            serviceName = "my-mac._androidcontinuity._tcp.",
        )
        assertEquals(2, device.protoMajor)
        assertEquals(1, device.protoMinor)
        assertEquals("MacBook Pro", device.deviceName)
        assertEquals("my-mac._androidcontinuity._tcp.", device.serviceName)
    }
}
