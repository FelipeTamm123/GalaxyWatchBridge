package com.felipetamm.watchbridge

import android.annotation.SuppressLint
import android.app.Service
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
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Wear OS BLE peripheral for the iOS Watch Bridge app.
 *
 * ## Why this exists
 *
 * Galaxy Watch 4 and later run Wear OS 3+, which dropped iOS support entirely: there is no
 * Galaxy Wearable app for iPhone and no companion protocol to hook into. The only way an
 * iPhone can talk to one of these watches is to bypass the companion ecosystem and speak
 * raw BLE GATT — which means the watch has to act as the peripheral and expose a custom
 * service, because nothing suitable is exposed by default.
 *
 * That is what this service does. Run it on the watch, and the iOS app can discover,
 * connect, subscribe, and exchange framed packets.
 *
 * ## Constraints worth knowing before you build on this
 *
 * - **Foreground only, realistically.** Wear OS aggressively suspends background work and
 *   BLE advertising is a battery sink. Keep the watch activity visible during development.
 * - **UUIDs must match byte-for-byte** with `BLEConstants.swift`. A mismatch presents as a
 *   watch that advertises but exposes no services — the most confusing possible failure.
 * - **Little-endian everywhere.** `ByteBuffer` defaults to BIG_endian; Swift's integer
 *   loads are little-endian on ARM. Every buffer below sets the order explicitly. Getting
 *   this wrong yields plausible-looking garbage rather than an error.
 * - **The CCCD descriptor is mandatory.** Without a Client Characteristic Configuration
 *   descriptor on the notify characteristic, iOS's `setNotifyValue(true:)` fails and no
 *   telemetry ever arrives.
 */
class GattServerService : Service() {

    companion object {
        private const val TAG = "GattServerService"

        // Must match BLEConstants.swift exactly.
        val SERVICE_UUID: UUID = UUID.fromString("8E7C0001-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val TELEMETRY_UUID: UUID = UUID.fromString("8E7C0002-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val COMMAND_UUID: UUID = UUID.fromString("8E7C0003-4B2A-4E1F-9C3D-5A6B7C8D9E0F")
        val DEVICE_INFO_UUID: UUID = UUID.fromString("8E7C0004-4B2A-4E1F-9C3D-5A6B7C8D9E0F")

        /** Client Characteristic Configuration Descriptor — the SIG-assigned 0x2902. */
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
    }

    private lateinit var bluetoothManager: BluetoothManager
    private var gattServer: BluetoothGattServer? = null
    private var telemetryCharacteristic: BluetoothGattCharacteristic? = null

    /** Centrals that have written 0x0001 to the CCCD. Only these receive notifications. */
    private val subscribers = Collections.synchronizedSet(mutableSetOf<BluetoothDevice>())

    private val scope = CoroutineScope(SupervisorJob())
    private var streamJob: Job? = null
    private var sequence = 0

    // MARK: - Lifecycle

    override fun onCreate() {
        super.onCreate()
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        startGattServer()
        startAdvertising()
    }

    override fun onDestroy() {
        stopAdvertising()
        gattServer?.close()
        gattServer = null
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // MARK: - GATT server

    @SuppressLint("MissingPermission") // Caller must hold BLUETOOTH_CONNECT (API 31+).
    private fun startGattServer() {
        val server = bluetoothManager.openGattServer(this, serverCallback)
        if (server == null) {
            Log.e(TAG, "openGattServer returned null — is Bluetooth enabled?")
            return
        }
        gattServer = server

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // Watch -> phone. NOTIFY only; no read property, so iOS must subscribe.
        val telemetry = BluetoothGattCharacteristic(
            TELEMETRY_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            0 // No read/write permission needed for a notify-only characteristic.
        ).apply {
            // Without this descriptor, iOS setNotifyValue(true:) fails silently.
            addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        telemetryCharacteristic = telemetry
        service.addCharacteristic(telemetry)

        // Phone -> watch. WRITE (acknowledged) so the iOS side gets a confirmation.
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
    }

    private val serverCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                subscribers.remove(device)
                if (subscribers.isEmpty()) stopStreaming()
                Log.i(TAG, "Central disconnected; ${subscribers.size} subscriber(s) remain")
            } else {
                Log.i(TAG, "Central connected: ${device.address}")
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

            // Respond before doing any work: iOS is waiting on didWriteValueFor, and a
            // slow handler here shows up there as a write timeout.
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }

            handleCommandFrame(device, value)
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
                // 0x0001 = notifications on, 0x0002 = indications, 0x0000 = off.
                val enabled = value.size >= 2 && value[0].toInt() == 0x01
                if (enabled) subscribers.add(device) else subscribers.remove(device)
                Log.i(TAG, "Notifications ${if (enabled) "enabled" else "disabled"} for ${device.address}")
                if (!enabled && subscribers.isEmpty()) stopStreaming()
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.i(TAG, "MTU negotiated: $mtu bytes")
        }
    }

    // MARK: - Command handling

    private fun handleCommandFrame(device: BluetoothDevice, raw: ByteArray) {
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
                val requested = if (payload.size >= 2) {
                    (ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF).toLong()
                } else {
                    1000L
                }
                val interval = requested.coerceIn(MIN_STREAM_INTERVAL_MS, MAX_STREAM_INTERVAL_MS)
                startStreaming(interval)
                sendAck(seq)
            }

            OP_STOP_STREAM -> {
                stopStreaming()
                sendAck(seq)
            }

            OP_REQUEST_SAMPLE -> {
                scope.launch { notifyTelemetry(readSensors()) }
                sendAck(seq)
            }

            OP_VIBRATE -> {
                val ms = if (payload.size >= 2) {
                    (ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF).toLong()
                } else {
                    300L
                }
                vibrate(ms)
                sendAck(seq)
            }

            else -> {
                Log.w(TAG, "Unknown opcode 0x%02X".format(opcode))
                sendError("unknown opcode")
            }
        }
    }

    // MARK: - Streaming

    private fun startStreaming(intervalMs: Long) {
        stopStreaming()
        Log.i(TAG, "Streaming every ${intervalMs}ms")
        streamJob = scope.launch {
            while (isActive && subscribers.isNotEmpty()) {
                notifyTelemetry(readSensors())
                delay(intervalMs)
            }
        }
    }

    private fun stopStreaming() {
        streamJob?.cancel()
        streamJob = null
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

        // Copy the set before iterating: onConnectionStateChange can mutate it from
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
    }

    private fun notifyTelemetry(sample: Sample) = notify(OP_TELEMETRY, sample.encode())

    private fun sendAck(sequence: Byte) = notify(OP_ACK, byteArrayOf(sequence))

    private fun sendError(message: String) = notify(OP_ERROR, message.toByteArray(Charsets.UTF_8))

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
     * Placeholder sensor read.
     *
     * Replace with real sources:
     *  - Heart rate / steps: Health Services (`androidx.health.services.client`), which is
     *    the Wear OS-sanctioned API and handles batching and power management. Requires
     *    the BODY_SENSORS and ACTIVITY_RECOGNITION permissions.
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
        // Wire up VibratorManager (API 31+) or Vibrator here.
    }

    // MARK: - Advertising

    @SuppressLint("MissingPermission") // Caller must hold BLUETOOTH_ADVERTISE (API 31+).
    private fun startAdvertising() {
        val advertiser = bluetoothManager.adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "No BLE advertiser — peripheral role unsupported or Bluetooth is off")
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0) // Advertise until explicitly stopped.
            .build()

        // The service UUID must be in the advertisement, not just the GATT table — the
        // iOS side runs a filtered scan and will never see the watch without it.
        //
        // A 128-bit UUID consumes 16 of the 31-byte advertisement budget, which is why the
        // device name is pushed into the scan response rather than the primary packet.
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
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.i(TAG, "Advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "advertisement payload exceeds 31 bytes"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers"
                ADVERTISE_FAILED_ALREADY_STARTED -> "already advertising"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "peripheral role unsupported"
                else -> "code $errorCode"
            }
            Log.e(TAG, "Advertising failed: $reason")
        }
    }
}
