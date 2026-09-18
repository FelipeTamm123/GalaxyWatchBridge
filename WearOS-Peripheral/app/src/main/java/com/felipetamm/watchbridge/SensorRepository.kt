package com.felipetamm.watchbridge

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.util.Log
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.PassiveListenerCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DataTypeAvailability
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.PassiveListenerConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Real sensor readings, replacing the synthetic values the bridge shipped with.
 *
 * ## Why Health Services rather than SensorManager
 *
 * Heart rate, steps, calories and distance come from **Health Services**
 * (`androidx.health.services`), the Wear OS-sanctioned API. It batches readings, manages
 * sensor power itself, and — decisively on a Galaxy Watch — Samsung restricts direct
 * `Sensor.TYPE_HEART_RATE` access, so the raw SensorManager path is unreliable there.
 *
 * Two different Health Services clients are needed, because the data has two shapes:
 *
 * - **MeasureClient** for heart rate: an instantaneous sample that only flows while
 *   something is actively registered. Registering keeps the optical sensor powered, which
 *   is why it is only registered while a phone is subscribed.
 * - **PassiveMonitoringClient** for daily step / calorie / distance totals: cumulative
 *   counters the platform maintains all day. Asking for these does not power anything up.
 *
 * Battery comes from `BatteryManager` (no permission, no receiver) and on-wrist state from
 * `SensorManager`'s off-body sensor, which Health Services does not expose.
 *
 * ## Degradation is deliberate
 *
 * Every source is independent and optional. If Health Services is unavailable, the
 * permission was denied, or the watch has no HR sensor, the affected field stays `null`
 * and everything else still flows. A partial telemetry packet is far more useful than a
 * failed one, and the phone already renders a missing heart rate as "—".
 *
 * ## Not compiled
 *
 * The Health Services generic types (`SampleDataPoint` vs `IntervalDataPoint`, and the
 * value types behind each `DataType`) are the most likely thing to need adjusting on first
 * build. Android Studio has a real compiler and autocomplete for this, unlike the iOS
 * half — let it guide you if a `getData` call disagrees.
 */
class SensorRepository(private val context: Context) {

    companion object {
        private const val TAG = "SensorRepository"
    }

    /**
     * Latest known values. `null` means "no reading available", which is distinct from
     * zero — a heart rate of 0 would be a medical emergency, not a missing sample.
     */
    data class Readings(
        val heartRate: Int? = null,
        val stepsToday: Int? = null,
        val caloriesToday: Double? = null,
        val distanceTodayMeters: Double? = null,
        val batteryPercent: Int? = null,
        val isCharging: Boolean = false,
        val isOnWrist: Boolean? = null,
        val heartRateAvailable: Boolean = false,
    )

    private val _readings = MutableStateFlow(Readings())
    val readings: StateFlow<Readings> = _readings.asStateFlow()

    private val healthClient by lazy { HealthServices.getClient(context) }
    private val sensorManager by lazy {
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    private val batteryManager by lazy {
        context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
    }

    private var isMeasuring = false

    // MARK: - Heart rate (MeasureClient)

    private val measureCallback = object : MeasureCallback {
        override fun onRegistered() {
            Log.i(TAG, "Heart rate measurement registered")
        }

        override fun onRegistrationFailed(throwable: Throwable) {
            // Usually a denied BODY_SENSORS permission rather than a hardware fault.
            Log.e(TAG, "Heart rate registration failed: ${throwable.message}")
            _readings.update { it.copy(heartRateAvailable = false) }
        }

        override fun onAvailabilityChanged(
            dataType: DeltaDataType<*, *>,
            availability: Availability
        ) {
            if (availability is DataTypeAvailability) {
                val available = availability == DataTypeAvailability.AVAILABLE
                Log.i(TAG, "Heart rate availability: $availability")
                _readings.update {
                    it.copy(
                        heartRateAvailable = available,
                        // Drop a stale reading the moment the sensor stops being
                        // available, so the phone shows "—" instead of a frozen number
                        // that looks live.
                        heartRate = if (available) it.heartRate else null
                    )
                }
            }
        }

        override fun onDataReceived(data: DataPointContainer) {
            val bpm = data.getData(DataType.HEART_RATE_BPM).lastOrNull()?.value ?: return
            // Health Services reports 0.0 when the sensor is powered but has no contact.
            if (bpm <= 0.0) return
            _readings.update { it.copy(heartRate = bpm.toInt()) }
        }
    }

    // MARK: - Daily totals (PassiveMonitoringClient)

    private val passiveCallback = object : PassiveListenerCallback {
        override fun onRegistered() {
            Log.i(TAG, "Passive monitoring registered")
        }

        override fun onRegistrationFailed(throwable: Throwable) {
            Log.e(TAG, "Passive monitoring failed: ${throwable.message}")
        }

        override fun onPermissionLost() {
            // The user revoked ACTIVITY_RECOGNITION while running. Clear the values rather
            // than serving numbers that will silently never update again.
            Log.w(TAG, "Activity permission lost")
            _readings.update {
                it.copy(stepsToday = null, caloriesToday = null, distanceTodayMeters = null)
            }
        }

        override fun onNewDataPointsReceived(dataPoints: DataPointContainer) {
            val steps = dataPoints.getData(DataType.STEPS_DAILY).lastOrNull()?.value
            val calories = dataPoints.getData(DataType.CALORIES_DAILY).lastOrNull()?.value
            val distance = dataPoints.getData(DataType.DISTANCE_DAILY).lastOrNull()?.value

            _readings.update {
                it.copy(
                    stepsToday = steps?.toInt() ?: it.stepsToday,
                    caloriesToday = calories ?: it.caloriesToday,
                    distanceTodayMeters = distance ?: it.distanceTodayMeters
                )
            }
        }
    }

    // MARK: - On-wrist (SensorManager)

    private val offBodyListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            // 1.0 = on body, 0.0 = off body.
            val onWrist = event.values.firstOrNull()?.let { it >= 1.0f }
            _readings.update { it.copy(isOnWrist = onWrist) }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    // MARK: - Lifecycle

    /**
     * Subscribes to the daily totals and the off-body sensor. Cheap — neither powers up
     * hardware on its own.
     */
    fun start() {
        try {
            val config = PassiveListenerConfig.builder()
                .setDataTypes(
                    setOf(
                        DataType.STEPS_DAILY,
                        DataType.CALORIES_DAILY,
                        DataType.DISTANCE_DAILY
                    )
                )
                .build()
            healthClient.passiveMonitoringClient
                .setPassiveListenerCallback(config, passiveCallback)
        } catch (e: Exception) {
            // Never let a missing sensor take the GATT server down with it.
            Log.e(TAG, "Passive monitoring unavailable: ${e.message}")
        }

        val offBody = sensorManager.getDefaultSensor(Sensor.TYPE_LOW_LATENCY_OFFBODY_DETECT)
        if (offBody == null) {
            Log.i(TAG, "No off-body sensor on this device")
        } else {
            sensorManager.registerListener(
                offBodyListener,
                offBody,
                SensorManager.SENSOR_DELAY_NORMAL
            )
        }

        refreshBattery()
    }

    /**
     * Starts heart rate measurement.
     *
     * Kept separate from [start] because this one **powers the optical sensor**, which is
     * the single largest battery draw here. Call it only while a phone is actually
     * subscribed, and stop it as soon as that stops being true.
     */
    fun startHeartRate() {
        if (isMeasuring) return
        try {
            healthClient.measureClient
                .registerMeasureCallback(DataType.HEART_RATE_BPM, measureCallback)
            isMeasuring = true
        } catch (e: Exception) {
            Log.e(TAG, "Cannot measure heart rate: ${e.message}")
            _readings.update { it.copy(heartRateAvailable = false) }
        }
    }

    fun stopHeartRate() {
        if (!isMeasuring) return
        try {
            healthClient.measureClient
                .unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, measureCallback)
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering heart rate: ${e.message}")
        }
        isMeasuring = false
        _readings.update { it.copy(heartRate = null) }
    }

    fun stop() {
        stopHeartRate()
        try {
            healthClient.passiveMonitoringClient.clearPassiveListenerCallbackAsync()
        } catch (e: Exception) {
            Log.e(TAG, "Error clearing passive listener: ${e.message}")
        }
        sensorManager.unregisterListener(offBodyListener)
    }

    // MARK: - Battery

    /**
     * Battery is polled rather than observed: `ACTION_BATTERY_CHANGED` fires far more
     * often than telemetry is sent, and `getIntProperty` is a cheap direct read with no
     * receiver to register or leak.
     */
    fun refreshBattery() {
        val percent = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        _readings.update {
            it.copy(
                // Returns Integer.MIN_VALUE when unsupported; treat anything outside
                // 0..100 as no reading.
                batteryPercent = percent.takeIf { p -> p in 0..100 },
                isCharging = batteryManager.isCharging
            )
        }
    }
}
