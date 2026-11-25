package com.toolbox.app.idphoto

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 证件照处理管线：解码 → 裁切 → U²-Net 抠图 → 柔和边缘 → 背景合成 →
 * 缩放到目标像素 → JPEG 二分压缩到目标体积。
 *
 * 全部方法都是同步阻塞的，调用方负责放到后台线程执行。
 */
object IdPhotoProcessor {

    /** 处理结果。 */
    data class Result(
        val path: String,
        val width: Int,
        val height: Int,
        val bytes: Long,
    )

    /** 解码时长边上限：证件照最终只有几百像素，原图没必要全量解码。 */
    private const val DECODE_LONG_SIDE = 2400

    /** 边缘收紧窗口：alpha 在这段区间内做平滑过渡，边缘干净又不锯齿。 */
    private const val EDGE_LOW = 0.35f
    private const val EDGE_HIGH = 0.62f

    /** 边缘收缩滑块把整个窗口往高置信度方向平移，最多平移到 1.0。 */
    private const val EDGE_SHRINK_SPAN = 1f - EDGE_HIGH

    /** 最近一次抠图结果：换底色 / 调边缘时直接复用，不重跑 U²-Net。 */
    private class Matte(val person: Bitmap, val alpha: FloatArray, val maskSide: Int)

    private val matteLock = Any()
    private var lastMatte: Matte? = null

    // ---------------------------------------------------------------- 人脸检测

    /**
     * 人脸检测：返回人脸数量、欧拉角与第一张人脸的包围盒（已按 EXIF 旋转）。
     */
    fun detectFace(context: Context, path: String): Map<String, Any> {
        val file = File(path)
        require(file.isFile) { "图片不存在" }
        val image = InputImage.fromFilePath(context, android.net.Uri.fromFile(file))
        val options = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_NONE)
            // 6% 时背景里的小人像 / 花纹容易触发误检；证件照的人脸占比
            // 远大于 8%，抬高一点能明显减少「检测到多张人脸」的假报警。
            .setMinFaceSize(0.08f)
            .build()
        val detector = FaceDetection.getClient(options)
        try {
            val faces = Tasks.await(detector.process(image), 20, TimeUnit.SECONDS)
            val largest = faces.maxByOrNull { it.boundingBox.height() * it.boundingBox.width() }
            val box = largest?.boundingBox
            // 把所有框都交给 Dart：由面积 / IoU 过滤误检，比在原生侧写死阈值
            // 更好调，也能让用户看到「其实只有一张脸」时继续处理。
            val allBoxes = faces.map { face ->
                val b = face.boundingBox
                mapOf(
                    "left" to b.left,
                    "top" to b.top,
                    "right" to b.right,
                    "bottom" to b.bottom,
                )
            }
            return mapOf(
                "count" to faces.size,
                "faces" to allBoxes,
                "eulerX" to (largest?.headEulerAngleX ?: 0f).toDouble(),
                "eulerY" to (largest?.headEulerAngleY ?: 0f).toDouble(),
                "eulerZ" to (largest?.headEulerAngleZ ?: 0f).toDouble(),
                "left" to (box?.left ?: 0),
                "top" to (box?.top ?: 0),
                "right" to (box?.right ?: 0),
                "bottom" to (box?.bottom ?: 0),
                "width" to image.width,
                "height" to image.height,
            )
        } finally {
            detector.close()
        }
    }

    // ------------------------------------------------------------------ 主流程

    fun process(
        context: Context,
        sourcePath: String,
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        background: Int,
        outWidth: Int,
        outHeight: Int,
        maxKb: Int,
        edgeShrink: Float,
        onProgress: (String, Double) -> Unit,
    ): Result {
        require(outWidth > 0 && outHeight > 0) { "目标尺寸无效" }
        val source = File(sourcePath)
        require(source.isFile) { "图片不存在" }

        val decoded = decodeRotated(sourcePath)
        val source0 = decoded.bitmap
        onProgress("matte", 0.15)
        try {
            // 裁切框是原图（ML Kit 坐标）像素，解码时可能降采样过，必须同比例换算。
            val scale = 1f / decoded.sample
            val cropLeft = (left * scale).toInt().coerceIn(0, source0.width - 1)
            val cropTop = (top * scale).toInt().coerceIn(0, source0.height - 1)
            val cropRight = (right * scale).toInt().coerceIn(cropLeft + 1, source0.width)
            val cropBottom = (bottom * scale).toInt().coerceIn(cropTop + 1, source0.height)
            require(cropRight - cropLeft >= 8 && cropBottom - cropTop >= 8) {
                "裁切区域无效，请重新框选"
            }
            var cropped = Bitmap.createBitmap(
                source0,
                cropLeft,
                cropTop,
                cropRight - cropLeft,
                cropBottom - cropTop,
            )
            if (cropped !== source0) source0.recycle()

            // 先缩到目标像素，再在这个尺度上做抠图合成，避免二次缩放糊边。
            val target = Bitmap.createScaledBitmap(cropped, outWidth, outHeight, true)
            if (target !== cropped) cropped.recycle()

            val segmenter = U2NetSegmenter(context)
            val maskSide = segmenter.size
            val alpha = try {
                segmenter.mask(target)
            } finally {
                segmenter.close()
            }
            // 缓存人像与掩码：之后只换底色 / 调边缘收缩时不用再跑一遍模型。
            synchronized(matteLock) {
                lastMatte?.person?.let { if (!it.isRecycled) it.recycle() }
                lastMatte = Matte(target, alpha, maskSide)
            }
            onProgress("composite", 0.55)
            return finish(
                context,
                target,
                alpha,
                maskSide,
                background,
                edgeShrink,
                maxKb,
                onProgress,
            )
        } finally {
            if (!source0.isRecycled) source0.recycle()
        }
    }

    /** 合成 + 压缩 + 落盘；完整处理与换底色共用这一段。 */
    private fun finish(
        context: Context,
        person: Bitmap,
        alpha: FloatArray,
        maskSide: Int,
        background: Int,
        edgeShrink: Float,
        maxKb: Int,
        onProgress: ((String, Double) -> Unit)? = null,
    ): Result {
        onProgress?.invoke("composite", 0.55)
        val composited = compositeWithBackground(
            person, alpha, maskSide, background, edgeShrink,
        )
        onProgress?.invoke("compress", 0.8)
        val outFile = File(
            context.cacheDir,
            "idphoto_${System.currentTimeMillis()}.jpg",
        )
        val bytes = writeJpegToLimit(composited, outFile, maxKb)
        val width = composited.width
        val height = composited.height
        composited.recycle()
        onProgress?.invoke("compress", 1.0)
        return Result(outFile.absolutePath, width, height, bytes)
    }

    /**
     * 只换底色 / 边缘收缩 / 体积：复用 [lastMatte]，毫秒级出图。
     *
     * 进程被回收或还没处理过图片时返回 null，Dart 侧会回退到完整流程。
     */
    fun recolor(context: Context, background: Int, edgeShrink: Float, maxKb: Int): Result? {
        val matte = synchronized(matteLock) { lastMatte } ?: return null
        if (matte.person.isRecycled) return null
        return finish(
            context,
            matte.person,
            matte.alpha,
            matte.maskSide,
            background,
            edgeShrink,
            maxKb,
        )
    }

    /** 解码结果：位图 + 实际降采样倍数（裁切框需要按此缩放）。 */
    private class Decoded(val bitmap: Bitmap, val sample: Int)

    /**
     * 按 EXIF 方向把图片摆正。
     *
     * ML Kit 的包围盒是「已旋转」坐标系，这里必须同样旋转，否则裁切框会错位。
     */
    private fun decodeRotated(path: String): Decoded {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "无法解码图片" }
        var sample = 1
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        while (longSide / (sample * 2) >= DECODE_LONG_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = BitmapFactory.decodeFile(path, options) ?: error("无法解码图片")
        val degrees = when (readOrientation(path)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (degrees == 0f) return Decoded(bitmap, sample)
        val matrix = Matrix().apply { postRotate(degrees) }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (rotated !== bitmap) bitmap.recycle()
        return Decoded(rotated, sample)
    }

    @Suppress("DEPRECATION")
    private fun readOrientation(path: String): Int = try {
        ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    /**
     * 把人像按 alpha 叠到纯色背景上。
     *
     * alpha 在 320×320 掩码上做双线性上采样，再用 [EDGE_LOW]~[EDGE_HIGH]
     * 收紧过渡带：既保留发丝细节，又不会出现半透明灰边。
     */
    private fun compositeWithBackground(
        person: Bitmap,
        alpha: FloatArray,
        maskSide: Int,
        background: Int,
        edgeShrink: Float,
    ): Bitmap {
        // 收缩滑块把过渡窗口整体右移：只有更「像人像」的像素才留下，
        // 原底色在发丝/肩线附近的半透明描边随之被吃掉。
        val shrink = edgeShrink.coerceIn(0f, 1f)
        val low = EDGE_LOW + shrink * EDGE_SHRINK_SPAN
        val high = EDGE_HIGH + shrink * EDGE_SHRINK_SPAN
        val width = person.width
        val height = person.height
        val source = IntArray(width * height)
        person.getPixels(source, 0, width, 0, 0, width, height)
        val bgR = (background shr 16) and 0xFF
        val bgG = (background shr 8) and 0xFF
        val bgB = background and 0xFF
        val out = IntArray(source.size)
        var covered = 0.0
        for (y in 0 until height) {
            // 采样点对齐到掩码像素中心，边缘不会整体偏移半像素。
            val my = ((y + 0.5f) * maskSide / height) - 0.5f
            val y0 = my.toInt().coerceIn(0, maskSide - 1)
            val y1 = (y0 + 1).coerceAtMost(maskSide - 1)
            val fy = (my - y0).coerceIn(0f, 1f)
            for (x in 0 until width) {
                val mx = ((x + 0.5f) * maskSide / width) - 0.5f
                val x0 = mx.toInt().coerceIn(0, maskSide - 1)
                val x1 = (x0 + 1).coerceAtMost(maskSide - 1)
                val fx = (mx - x0).coerceIn(0f, 1f)
                val top = alpha[y0 * maskSide + x0] * (1 - fx) + alpha[y0 * maskSide + x1] * fx
                val bottom = alpha[y1 * maskSide + x0] * (1 - fx) + alpha[y1 * maskSide + x1] * fx
                val raw = top * (1 - fy) + bottom * fy
                val a = ((raw - low) / (high - low)).coerceIn(0f, 1f)
                covered += a
                val pixel = source[y * width + x]
                val r = (((pixel shr 16) and 0xFF) * a + bgR * (1 - a)).toInt().coerceIn(0, 255)
                val g = (((pixel shr 8) and 0xFF) * a + bgG * (1 - a)).toInt().coerceIn(0, 255)
                val b = ((pixel and 0xFF) * a + bgB * (1 - a)).toInt().coerceIn(0, 255)
                out[y * width + x] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        // 全是背景说明没抠出人像（人物占比过低或图片不是人像）。
        require(covered / source.size > 0.02) { "没有识别到人像，请换一张更清晰的照片" }
        return Bitmap.createBitmap(out, width, height, Bitmap.Config.ARGB_8888)
    }

    /**
     * JPEG 二分压缩：质量从 95 往 30 找，取「不超过目标体积」的最高质量。
     *
     * 达不到目标时返回最低质量的结果，由 UI 如实显示实际体积。
     */
    private fun writeJpegToLimit(bitmap: Bitmap, outFile: File, maxKb: Int): Long {
        val target = if (maxKb <= 0) 0 else maxKb * 1024
        if (target <= 0) {
            val bytes = encode(bitmap, 95)
            outFile.writeBytes(bytes)
            return bytes.size.toLong()
        }
        var low = 30
        var high = 95
        var best: ByteArray = encode(bitmap, low)
        if (best.size <= target) {
            while (low <= high) {
                val mid = (low + high) / 2
                val candidate = encode(bitmap, mid)
                if (candidate.size <= target) {
                    best = candidate
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
        }
        outFile.writeBytes(best)
        return best.size.toLong()
    }

    private fun encode(bitmap: Bitmap, quality: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        return stream.toByteArray()
    }

    // ------------------------------------------------------------------ 导出

    /**
     * 保存到系统相册 `Pictures/XMtools`。
     *
     * Android 10+ 走 MediaStore，无需存储权限；9 及以下需要
     * WRITE_EXTERNAL_STORAGE，没授权时会返回 false，由 UI 提示改用存储空间。
     */
    fun saveToGallery(context: Context, path: String, name: String): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/XMtools",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        return try {
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: return false
            resolver.openOutputStream(uri)?.use { output ->
                file.inputStream().use { it.copyTo(output) }
            } ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}
