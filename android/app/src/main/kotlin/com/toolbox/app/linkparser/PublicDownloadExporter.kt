package com.toolbox.app.linkparser

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileInputStream

/**
 * 把应用私有目录里的成品文件导出到系统公共下载目录。
 *
 * - Android 10+：走 MediaStore 的 `Downloads` 集合，只需要写自己的条目，
 *   不需要用户授予「所有文件访问」这种重权限，文件在「文件管理 → 下载」里可见。
 * - Android 9 及以下：直接写 `Download/<子目录>`，依赖清单里的
 *   `WRITE_EXTERNAL_STORAGE`（已限定 maxSdkVersion=28）。
 *
 * 同目录同名文件已存在时自动加 `(1)`、`(2)` 后缀，不覆盖用户已有文件。
 */
object PublicDownloadExporter {

    /** 返回 `displayPath` / `localPath` 两项；失败抛异常由上层转成提示。 */
    fun export(
        context: Context,
        sourcePath: String,
        relativeDir: String,
        name: String,
    ): Map<String, String> {
        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            throw IllegalStateException("临时文件已不存在，请重新下载")
        }
        val safeName = sanitize(name).ifBlank { source.name }
        // 传进来的是 `Download/Toolbox/xxx`，Download 那一层交给 MediaStore / 公共目录自己拼。
        val sub = relativeDir.trim('/').removePrefix("Download").trim('/')
        val mime = mimeOf(safeName)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            exportViaMediaStore(context, source, sub, safeName, mime)
        } else {
            exportLegacy(source, sub, safeName)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun exportViaMediaStore(
        context: Context,
        source: File,
        sub: String,
        name: String,
        mime: String,
    ): Map<String, String> {
        val relativePath = if (sub.isEmpty()) "Download/" else "Download/$sub/"
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("系统拒绝创建下载文件")
        try {
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("无法写入下载目录")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }
        // 系统可能因为重名改了文件名，读回来才是准的。
        var displayName = name
        runCatching {
            resolver.query(
                uri,
                arrayOf(MediaStore.Downloads.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(MediaStore.Downloads.DISPLAY_NAME)
                    if (index >= 0) displayName = cursor.getString(index) ?: name
                }
            }
        }
        val displayPath = if (sub.isEmpty()) {
            "Download/$displayName"
        } else {
            "Download/$sub/$displayName"
        }
        return mapOf(
            "displayPath" to displayPath,
            "localPath" to File(
                Environment.getExternalStorageDirectory(),
                displayPath,
            ).absolutePath,
        )
    }

    @Suppress("DEPRECATION")
    private fun exportLegacy(
        source: File,
        sub: String,
        name: String,
    ): Map<String, String> {
        val root = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        val dir = if (sub.isEmpty()) root else File(root, sub)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建下载目录：${dir.absolutePath}")
        }
        val target = uniqueFile(dir, name)
        FileInputStream(source).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        val displayPath = if (sub.isEmpty()) {
            "Download/${target.name}"
        } else {
            "Download/$sub/${target.name}"
        }
        return mapOf(
            "displayPath" to displayPath,
            "localPath" to target.absolutePath,
        )
    }

    private fun uniqueFile(dir: File, name: String): File {
        val first = File(dir, name)
        if (!first.exists()) return first
        val ext = first.extension
        val stem = if (ext.isEmpty()) name else name.dropLast(ext.length + 1)
        var index = 1
        while (true) {
            val candidate = File(
                dir,
                if (ext.isEmpty()) "$stem($index)" else "$stem($index).$ext",
            )
            if (!candidate.exists()) return candidate
            index++
        }
    }

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    /** 只去掉文件系统不接受的字符，保留中文与扩展名。 */
    private fun sanitize(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").trim()
}
