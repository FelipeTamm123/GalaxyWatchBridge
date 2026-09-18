package com.felipetamm.watchbridge

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Wear OS BLE peripheral for the iOS Watch Bridge app.
 *
 * ## Why this exists
 *
 * Galaxy Watch 4 and later run Wear OS 3+, which dropped iOS support entirely: no Galaxy
 * Wearable app for iPhone, no companion protocol to hook into. The only way an iPhone can
 * talk to one of these watches is to bypass the companion ecosystem and speak raw BLE
 * GATT — which means the watch must act as the peripheral and expose a custom service,
 * because nothing suitable is exposed by default.
 *
 * ## Constraints worth knowing before building on this
 *
 * - **UUIDs must match `BLEConstants.swift` byte-for-byte.** A mismatch presents as a
 *   watch that advertises but exposes no services — the most confusing failure here.
 * - **Little-endian everywhere.** `ByteBuffer` defaults to BIG_endian; Swift's integer
 *   loads are little-endian. Every buffer below sets the order explicitly. Getting this
 *   wrong yields plausible-looking garbage rather than an error.
 * - **The CCCD descriptor is mandatory.** Without a Client Characteristic Configuration
 *   descriptor on the notify characteristic, iOS `setNotifyValue(true:)` fails and no
 *   telemetry ever arrives.
 * - **Foreground service, started promptly.** On API 34+ a service declaring
 *   `foregroundServiceType` must call `startForeground()` within a few seconds of
 *   starting, or the system kills it with `ForegroundServiceDidNotStartInTimeException`.
 *   That happens first thing in [onStartCommand], before any Bluetooth work.
 */
class GattServerService : LifecycleService() {

    companion object {
        private const val TAG = "GattServerService"

        private const val CHANNEL_ID = "ble_bridge"
        private const val NOTIFICATION_ID = 1

        const val ACTION_STOP = "com.felipetamm.watchbridge.STOP"

        // Must match BLEConstants.swift exactly.
        val SERVICE_UUID: UUID = UUID.fromString("8E7C0001-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val TELEMETRY_UUID: UUID = UUID.fromString("8E7C0002-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val COMMAND_UUID: UUID = UUID.fromString("8E7C0003-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val DEVICE_INFO_UUID: UUID = UUID.fromString("8E7C0004-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

        /** Client Characteristic Configuration Descriptor — SIG-assigned 0x2902. */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

        // Opcodes — mirror of the Swift `Opcode` enum.
        private const val OP_TELEMETRY: Byte = 0x01
        private const val OP_START_STREAM: Byte = 0x10
        private const val OP_STOP_STREAM: Byte = 0x11
        private const val OP_REQUEST_SAMPLE: Byte = 0x12
        private const val OP_VIBRATE: Byte = 0x13
        private const val OP_ACK: Byte = 0x7E
        private const val OP_ERROR: Byte = 0x7F

        private const val FRAME_HEADER_SIZE = 4
        private const val MIN_STREAM_INTERVAL_MS = 200L
        private const val MAX_STREAM_INTERVAL_MS = 60_000L

        /**
         * Observable state for the watch UI.
         *
         * Lives in the companion object so the Activity can read it without binding to the
         * service. Same reasoning as the iOS side's log console: BLE failures are silent,
         * so showing the actual state is the only way to tell "not advertising" apart from
         * "advertising but the phone never subscribed".
         */
        private val _state = MutableStateFlow(ServerState())
        val state: StateFlow<ServerState> = _state.asStateFlow()
    }

    data class ServerState(
        val isRunning: Boolean = false,
        val isAdvertising: Boolean = false,
        val subscriberCount: Int = 0,
        val isStreaming: Boolean = false,
        val packetsSent: Int = 0,
        val lastEvent: String = "Idle",
        val error: String? = null,
    )

    private lateinit var bluetoothManager: BluetoothManager
    private var gattServer: BluetoothGattServer? = null
    private var telemetryCharacteristic: BluetoothGattCharacteristic? = null

    /** Centrals that wrote 0x0001 to the CCCD. Only these receive notifications. */
    private val subscribers = Collections.synchronizedSet(mutableSetOf<BluetoothDevice>())

    private var streamJob: Job? = null
    private var sequence = 0

    // MARK: - Lifecycle

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        // First, before anything that could throw or block. On API 34+ the system gives a
        // typed foreground service only a few seconds to post its notification.
        createNotificationChannel()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification("Starting…"),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
        )

        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            fail("Bluetooth is off")
            return START_NOT_STICKY
        }

        if (!startGattServer()) return START_NOT_STICKY
        startAdvertising()

        _state.update { it.copy(isRunning = true, error = null, lastEvent = "Server open") }
        return START_STICKY
    }

    override fun onDestroy() {
        stopStreaming()
        stopAdvertising()
        gattServer?.close()
        gattServer = null
        subscribers.clear()
        _state.update {
            ServerState(lastEvent = "Stopped")
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent): IBinder? {
        super.onBind(intent)
        return null
    }

    private fun fail(message: String) {
        Log.e(TAG, message)
        _state.update { it.copy(isRunning = false, error = message, lastEvent = message) }
        stopSelf()
    }

    // MARK: - Notification

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            // LOW keeps it silent: this is a status indicator, not an alert.
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, GattServerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_bridge)
            .setOngoing(true)
            .setSilent(true)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun updateNotification(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    // MARK: - GATT server

    @SuppressLint("MissingPermission") // BLUETOOTH_CONNECT checked by MainActivity.
    private fun startGattServer(): Boolean {
        val server = bluetoothManager.openGattServer(this, serverCallback)
        if (server == null) {
            // Almost always a missing BLUETOOTH_CONNECT grant rather than a real fault.
            fail("openGattServer failed — check Bluetooth permissions")
            return false
        }
        gattServer = server

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // Watch -> phone. NOTIFY only; no read property, so iOS must subscribe.
        val telemetry = BluetoothGattCharacteristic(
            TELEMETRY_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            0 // A notify-only characteristic needs no read/write permission.
        ).apply {
            addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        telemetryCharacteristic = telemetry
        service.addCharacteristic(telemetry)

        // Phone -> watch. WRITE (acknowledged) so iOS gets a confirmation.
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                COMMAND_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
        )

        service.addCharacteristic(
            BluetoothGattCharacteristic(
                DEVICE_INFO_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
        )

        server.addService(service)
        Log.i(TAG, "GATT server open with service $SERVICE_UUID")
        return true
    }

    private val serverCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                subscribers.remove(device)
                if (subscribers.isEmpty()) stopStreaming()
                Log.i(TAG, "Central disconnected; ${subscribers.size} subscriber(s) remain")
                publish("Central disconnected")
            } else {
                Log.i(TAG, "Central connected: ${device.address}")
                publish("Central connected")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != DEVICE_INFO_UUID) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null
                )
                return
            }

            val json = """{"model":"${Build.MODEL}","sdk":${Build.VERSION.SDK_INT},"protocol":1}"""
            val bytes = json.toByteArray(Charsets.UTF_8)

            // A long value arrives as several offset reads; serve the requested slice or
            // iOS receives a truncated payload.
            val slice = if (offset >= bytes.size) ByteArray(0) else bytes.copyOfRange(offset, bytes.size)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid != COMMAND_UUID) {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, 0, null
                    )
                }
                return
            }

            // Respond BEFORE doing any work: iOS is waiting on didWriteValueFor, and a slow
            // handler here surfaces there as a write timeout.
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }

            handleCommandFrame(value)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                // 0x0001 = notifications, 0x0002 = indications, 0x0000 = off.
                val enabled = value.size >= 2 && value[0].toInt() == 0x01
                if (enabled) subscribers.add(device) else subscribers.remove(device)
                Log.i(TAG, "Notifications ${if (enabled) "enabled" else "disabled"} for ${device.address}")
                if (!enabled && subscribers.isEmpty()) stopStreaming()
                publish(if (enabled) "Phone subscribed" else "Phone unsubscribed")
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.i(TAG, "MTU negotiated: $mtu bytes")
            publish("MTU $mtu")
        }
    }

    // MARK: - Command handling

    private fun handleCommandFrame(raw: ByteArray) {
        if (raw.size < FRAME_HEADER_SIZE) {
            Log.w(TAG, "Runt frame: ${raw.size} bytes")
            return
        }

        val header = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        val opcode = header.get()
        val seq = header.get()
        val payloadLength = header.short.toInt() and 0xFFFF

        if (raw.size < FRAME_HEADER_SIZE + payloadLength) {
            Log.w(TAG, "Truncated frame: declared $payloadLength, have ${raw.size - FRAME_HEADER_SIZE}")
            return
        }
        val payload = raw.copyOfRange(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + payloadLength)

        when (opcode) {
            OP_START_STREAM -> {
                val requested = readUInt16(payload) ?: 1000L
                startStreaming(requested.coerceIn(MIN_STREAM_INTERVAL_MS, MAX_STREAM_INTERVAL_MS))
                sendAck(seq)
            }

            OP_STOP_STREAM -> {
                stopStreaming()
                publish("Stream stopped")
                sendAck(seq)
            }

            OP_REQUEST_SAMPLE -> {
                lifecycleScope.launch { notifyTelemetry(readSensors()) }
                publish("Sample requested")
                sendAck(seq)
            }

            OP_VIBRATE -> {
                vibrate(readUInt16(payload) ?: 300L)
                sendAck(seq)
            }

            else -> {
                Log.w(TAG, "Unknown opcode 0x%02X".format(opcode))
                sendError("unknown opcode")
            }
        }
    }

    private fun readUInt16(payload: ByteArray): Long? =
        if (payload.size >= 2) {
            (ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF).toLong()
        } else {
            null
        }

    // MARK: - Streaming

    private fun startStreaming(intervalMs: Long) {
        stopStreaming()
        Log.i(TAG, "Streaming every ${intervalMs}ms")
        _state.update { it.copy(isStreaming = true, lastEvent = "Streaming @ ${intervalMs}ms") }
        updateNotification("Streaming every ${intervalMs}ms")

        streamJob = lifecycleScope.launch {
            while (isActive && subscribers.isNotEmpty()) {
                notifyTelemetry(readSensors())
                delay(intervalMs)
            }
            _state.update { it.copy(isStreaming = false) }
        }
    }

    private fun stopStreaming() {
        streamJob?.cancel()
        streamJob = null
        _state.update { it.copy(isStreaming = false) }
    }

    // MARK: - Frame emission

    @SuppressLint("MissingPermission")
    private fun notify(opcode: Byte, payload: ByteArray) {
        val characteristic = telemetryCharacteristic ?: return
        val server = gattServer ?: return

        val frame = ByteBuffer.allocate(FRAME_HEADER_SIZE + payload.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put(opcode)
            .put((++sequence and 0xFF).toByte())
            .putShort(payload.size.toShort())
            .put(payload)
            .array()

        // Snapshot before iterating: onConnectionStateChange can mutate the set from
        // another thread mid-loop.
        val targets = synchronized(subscribers) { subscribers.toList() }
        for (device in targets) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(device, characteristic, false, frame)
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = frame
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, characteristic, false)
            }
        }

        if (opcode == OP_TELEMETRY && targets.isNotEmpty()) {
            _state.update { it.copy(packetsSent = it.packetsSent + 1) }
        }
    }

    private fun notifyTelemetry(sample: Sample) = notify(OP_TELEMETRY, sample.encode())

    private fun sendAck(sequence: Byte) = notify(OP_ACK, byteArrayOf(sequence))

    private fun sendError(message: String) = notify(OP_ERROR, message.toByteArray(Charsets.UTF_8))

    private fun publish(event: String) {
        _state.update {
            it.copy(subscriberCount = subscribers.size, lastEvent = event)
        }
    }

    // MARK: - Sensors

    /**
     * One telemetry sample, encoded to the 16-byte layout documented in
     * `TelemetryPacket.swift`.
     */
    data class Sample(
        val epochMillis: Long,
        val heartRate: Int,
        val steps: Int,
        val batteryPercent: Int,
        val isCharging: Boolean,
        val isOnWrist: Boolean,
        val hasSensorContact: Boolean
    ) {
        fun encode(): ByteArray {
            var flags = 0
            if (isCharging) flags = flags or 0b001
            if (isOnWrist) flags = flags or 0b010
            if (hasSensorContact) flags = flags or 0b100

            return ByteBuffer.allocate(16)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putLong(epochMillis)
                .putShort(heartRate.coerceIn(0, 65535).toShort())
                .putInt(steps.coerceAtLeast(0))
                .put(batteryPercent.coerceIn(0, 100).toByte())
                .put(flags.toByte())
                .array()
        }
    }

    /**
     * Placeholder sensor read — synthetic values, so the link can be validated before any
     * sensor plumbing exists.
     *
     * Replace with real sources:
     *  - Heart rate / steps: Health Services (`androidx.health.services.client`), the
     *    Wear OS-sanctioned API; handles batching and power management. Needs BODY_SENSORS
     *    and ACTIVITY_RECOGNITION.
     *  - Battery: `registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))`.
     *  - On-wrist: `Sensor.TYPE_LOW_LATENCY_OFFBODY_DETECT` via SensorManager.
     */
    private fun readSensors(): Sample = Sample(
        epochMillis = System.currentTimeMillis(),
        heartRate = (60..100).random(),
        steps = 8_000 + (0..500).random(),
        batteryPercent = 64,
        isCharging = false,
        isOnWrist = true,
        hasSensorContact = true
    )

    private fun vibrate(durationMs: Long) {
        Log.i(TAG, "Vibrate ${durationMs}ms")
        publish("Buzzed ${durationMs}ms")

        val manager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager ?: return
        manager.defaultVibrator.vibrate(
            VibrationEffect.createOneShot(
                durationMs.coerceIn(50, 2000),
                VibrationEffect.DEFAULT_AMPLITUDE
            )
        )
    }

    // MARK: - Advertising

    @SuppressLint("MissingPermission") // BLUETOOTH_ADVERTISE checked by MainActivity.
    private fun startAdvertising() {
        val advertiser = bluetoothManager.adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            fail("No BLE advertiser — peripheral role unsupported")
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0) // Advertise until explicitly stopped.
            .build()

        // The service UUID must be in the ADVERTISEMENT, not just the GATT table — the iOS
        // side runs a filtered scan and will never see the watch without it.
        //
        // A 128-bit UUID eats 16 of the 31-byte advertisement budget, which is why the
        // device name goes in the scan response instead of the primary packet.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        bluetoothManager.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        _state.update { it.copy(isAdvertising = false) }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "Advertising started")
            _state.update { it.copy(isAdvertising = true, lastEvent = "Advertising") }
            updateNotification("Advertising — waiting for phone")
        }

        override fun onStartFailure(errorCode: Int) {
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "advertisement exceeds 31 bytes"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers"
                ADVERTISE_FAILED_ALREADY_STARTED -> "already advertising"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "peripheral role unsupported"
                else -> "code $errorCode"
            }
            Log.e(TAG, "Advertising failed: $reason")
            _state.update {
                it.copy(isAdvertising = false, error = reason, lastEvent = "Advertising failed")
            }
        }
    }
}
