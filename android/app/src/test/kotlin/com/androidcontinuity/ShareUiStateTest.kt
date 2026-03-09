package com.androidcontinuity

import android.net.Uri
import com.androidcontinuity.discovery.DiscoveredDevice
import com.androidcontinuity.ui.share.ScreenState
import com.androidcontinuity.ui.share.ShareUiState
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareUiStateTest {

    @Test
    fun `default state has correct values`() {
        val state = ShareUiState()
        assertTrue(state.imageUris.isEmpty())
        assertTrue(state.discoveredDevices.isEmpty())
        assertFalse(state.isDiscovering)
        assertEquals(null, state.selectedDevice)
        assertFalse(state.showDeviceSheet)
        assertEquals(ScreenState.SelectingDevice, state.screenState)
    }

    @Test
    fun `imageCount reflects URIs`() {
        val uri1 = mockk<Uri>()
        val uri2 = mockk<Uri>()
        val state = ShareUiState(imageUris = listOf(uri1, uri2))
        assertEquals(2, state.imageCount)
    }

    @Test
    fun `canSend requires images and device`() {
        val uri = mockk<Uri>()
        val device = DiscoveredDevice(
            name = "Mac", host = "1.2.3.4", grpcPort = 50051,
        )

        // No images, no device
        assertFalse(ShareUiState().canSend)

        // Images but no device
        assertFalse(ShareUiState(imageUris = listOf(uri)).canSend)

        // Device but no images
        assertFalse(ShareUiState(selectedDevice = device).canSend)

        // Both → can send
        assertTrue(ShareUiState(imageUris = listOf(uri), selectedDevice = device).canSend)
    }
}
