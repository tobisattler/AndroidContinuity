package com.androidcontinuity.di

import android.content.Context
import android.net.nsd.NsdManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module that provides application-wide dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    /**
     * Provides the system [NsdManager] for mDNS service discovery.
     */
    @Provides
    @Singleton
    fun provideNsdManager(
        @ApplicationContext context: Context,
    ): NsdManager {
        return context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }
}
