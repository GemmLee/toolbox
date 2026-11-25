package com.toolbox.app.watermark

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import androidx.core.content.ContextCompat

/// 拍照水印的实时定位：拿一次当前经纬度/海拔，取完即停，不做持续定位。
/// 权限由调用方（Activity）负责申请；未授权时返回 null，让 Dart 侧优雅降级。
class WatermarkGeo(private val context: Context) {

    data class Geo(val latitude: Double, val longitude: Double, val altitude: Double?)

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED

    /// 同步读取最近一次已知位置；没有缓存时返回 null。
    fun lastKnown(): Geo? {
        if (!hasPermission()) return null
        val manager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return null
        val location = bestLastKnown(manager) ?: return null
        return Geo(location.latitude, location.longitude, safeAltitude(location))
    }

    /// 请求一次新鲜定位，通过 [callback] 回传（主线程）。超时或失败回 null。
    fun requestOnce(timeoutMs: Long, callback: (Geo?) -> Unit) {
        if (!hasPermission()) {
            callback(null)
            return
        }
        val manager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null) {
            callback(null)
            return
        }
        var listener: LocationListener? = null
        val handler = android.os.Handler(Looper.getMainLooper())
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        // 唯一回调出口，保证 result 只 success 一次。
        fun finish(geo: Geo?) {
            if (!done.compareAndSet(false, true)) return
            listener?.let { manager.removeUpdates(it) }
            handler.removeCallbacksAndMessages(null)
            callback(geo)
        }

        // 已有缓存位置：直接回传，不再等待新定位，省电也更快。
        val cached = bestLastKnown(manager)
        if (cached != null) {
            finish(Geo(cached.latitude, cached.longitude, safeAltitude(cached)))
            return
        }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                finish(Geo(location.latitude, location.longitude, safeAltitude(location)))
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }
        try {
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
            ).filter { manager.isProviderEnabled(it) }
            if (providers.isEmpty()) {
                finish(null)
                return
            }
            for (provider in providers) {
                manager.requestLocationUpdates(provider, 0, 0f, listener, Looper.getMainLooper())
            }
            handler.postDelayed({ finish(null) }, timeoutMs)
        } catch (e: SecurityException) {
            finish(null)
        }
    }

    private fun bestLastKnown(manager: LocationManager): Location? {
        var best: Location? = null
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            val loc = try {
                manager.getLastKnownLocation(provider)
            } catch (e: SecurityException) {
                null
            } ?: continue
            if (best == null || loc.time > best.time) best = loc
        }
        return best
    }

    private fun safeAltitude(location: Location): Double? =
        if (location.hasAltitude()) location.altitude else null
}
