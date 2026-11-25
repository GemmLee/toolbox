package com.toolbox.app.idphoto

import android.content.Context
import android.graphics.Bitmap
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * U²-Net（u2netp，320×320，fp16 权重 / float32 输入输出）人像抠图。
 *
 * 模型随 APK 打包在 assets/u2netp.tflite，离线推理，不需要联网下载。
 * 输入按 ImageNet 均值方差归一化，输出 d0 单通道显著度图，做 min-max
 * 归一化后作为 alpha（与 U²-Net 官方 demo 的口径一致）。
 */
internal class U2NetSegmenter(private val context: Context) {

    private var interpreter: Interpreter? = null
    private var inputSize = DEFAULT_SIZE

    companion object {
        private const val MODEL_ASSET = "u2netp.tflite"
        private const val DEFAULT_SIZE = 320
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
    }

    /** 输入边长（模型固定 320）。 */
    val size: Int get() = ensure().let { inputSize }

    private fun ensure(): Interpreter {
        interpreter?.let { return it }
        val bytes = context.assets.open(MODEL_ASSET).use { it.readBytes() }
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        buffer.put(bytes)
        buffer.rewind()
        val options = Interpreter.Options().apply {
            setNumThreads(2)
            setUseXNNPACK(true)
        }
        val created = Interpreter(buffer, options)
        val shape = created.getInputTensor(0).shape()
        if (shape.size == 4) inputSize = shape[1]
        interpreter = created
        return created
    }

    /**
     * 推理一张图，返回 [size]×[size] 的 0..1 alpha（行优先，NHW）。
     *
     * 单通道显著度可能带 logits（未过 sigmoid），先判断量级再决定是否激活。
     */
    fun mask(bitmap: Bitmap): FloatArray {
        val engine = ensure()
        val side = inputSize
        val scaled = Bitmap.createScaledBitmap(bitmap, side, side, true)
        val pixels = IntArray(side * side)
        scaled.getPixels(pixels, 0, side, 0, 0, side, side)
        if (scaled !== bitmap) scaled.recycle()

        val inputTensor = engine.getInputTensor(0)
        val input = ByteBuffer
            .allocateDirect(inputTensor.numBytes())
            .order(ByteOrder.nativeOrder())
        // 模型是 fp16 权重、float32 输入输出；类型不符时明确报错，不要静默产出空掩码。
        require(inputTensor.dataType() == DataType.FLOAT32) {
            "不支持的模型输入类型：${inputTensor.dataType()}"
        }
        for (pixel in pixels) {
            for (channel in 0..2) {
                val value = ((pixel shr (16 - channel * 8)) and 0xFF) / 255f
                input.putFloat((value - MEAN[channel]) / STD[channel])
            }
        }
        input.rewind()

        val outputTensor = engine.getOutputTensor(0)
        require(outputTensor.dataType() == DataType.FLOAT32) {
            "不支持的模型输出类型：${outputTensor.dataType()}"
        }
        val output = ByteBuffer
            .allocateDirect(outputTensor.numBytes())
            .order(ByteOrder.nativeOrder())
        engine.run(input, output)
        output.rewind()
        val count = outputTensor.numElements()
        val raw = FloatArray(count) { output.float }

        // 输出是单通道显著度：NHWC[1,320,320,1] 与 NCHW[1,1,320,320]
        // 展平后行优先顺序相同，直接按 y*side+x 读取即可。
        val values = FloatArray(side * side) { raw.getOrElse(it) { 0f } }

        var min = Float.MAX_VALUE
        var max = -Float.MAX_VALUE
        for (value in values) {
            if (value < min) min = value
            if (value > max) max = value
        }
        // 未过 sigmoid 的 logits 量级远超 1，先激活再归一化。
        if (max > 1.5f || min < -0.5f) {
            min = Float.MAX_VALUE
            max = -Float.MAX_VALUE
            for (i in values.indices) {
                val activated = (1.0 / (1.0 + Math.exp(-values[i].toDouble()))).toFloat()
                values[i] = activated
                if (activated < min) min = activated
                if (activated > max) max = activated
            }
        }
        val range = if (max - min < 1e-6f) 1f else max - min
        for (i in values.indices) {
            values[i] = ((values[i] - min) / range).coerceIn(0f, 1f)
        }
        return smooth(values, side)
    }


    /** 3×3 均值模糊两遍：去掉掩码毛刺，让边缘过渡自然。 */
    private fun smooth(source: FloatArray, side: Int): FloatArray {
        var current = source
        repeat(2) {
            val next = FloatArray(current.size)
            for (y in 0 until side) {
                for (x in 0 until side) {
                    var sum = 0f
                    var count = 0
                    for (dy in -1..1) {
                        val ny = y + dy
                        if (ny < 0 || ny >= side) continue
                        for (dx in -1..1) {
                            val nx = x + dx
                            if (nx < 0 || nx >= side) continue
                            sum += current[ny * side + nx]
                            count++
                        }
                    }
                    next[y * side + x] = sum / count
                }
            }
            current = next
        }
        return current
    }

    fun close() {
        interpreter?.close()
        interpreter = null
    }
}
