package com.felipetamm.watchbridge

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText

/**
 * Minimal control surface for the GATT server.
 *
 * Its real job is requesting the runtime permissions. `BLUETOOTH_ADVERTISE` and
 * `BLUETOOTH_CONNECT` are runtime permissions from API 31 on, and declaring them in the
 * manifest is **not** enough: without the grant, `openGattServer()` returns null and
 * `startAdvertising()` never reports success — with no exception and nothing in the log to
 * say why. Everything else here is status readout.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { BridgeApp() }
    }
}

/** Permissions that must be granted before the service can do anything. */
private fun requiredPermissions(): Array<String> = buildList {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        add(Manifest.permission.BLUETOOTH_ADVERTISE)
        add(Manifest.permission.BLUETOOTH_CONNECT)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // Without this the foreground service notification is invisible. The service still
        // runs, but there is no way to stop it from the watch.
        add(Manifest.permission.POST_NOTIFICATIONS)
    }
}.toTypedArray()

private fun Context.hasAllPermissions(): Boolean =
    requiredPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

@Composable
private fun BridgeApp() {
    val context = LocalContext.current
    val state by GattServerService.state.collectAsState()

    var hasPermissions by remember { mutableStateOf(context.hasAllPermissions()) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        hasPermissions = granted.values.all { it }
    }

    val bluetoothEnabled = remember {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        manager?.adapter?.isEnabled == true
    }

    MaterialTheme {
        Scaffold(timeText = { TimeText() }) {
            ScalingLazyColumn(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                item {
                    Text(
                        text = "Watch Bridge",
                        style = MaterialTheme.typography.title3,
                        textAlign = TextAlign.Center
                    )
                }

                when {
                    !bluetoothEnabled -> item {
                        StatusBlock(
                            lines = listOf("Bluetooth is off" to Color(0xFFFF6B6B)),
                            note = "Turn Bluetooth on, then reopen this app."
                        )
                    }

                    !hasPermissions -> {
                        item {
                            StatusBlock(
                                lines = listOf("Permissions needed" to Color(0xFFFFB84D)),
                                note = "Advertising requires Bluetooth permissions granted at runtime."
                            )
                        }
                        item {
                            Chip(
                                modifier = Modifier.fillMaxWidth(),
                                label = { Text("Grant permissions") },
                                onClick = { permissionLauncher.launch(requiredPermissions()) },
                                colors = ChipDefaults.primaryChipColors()
                            )
                        }
                    }

                    else -> {
                        item {
                            StatusBlock(
                                lines = buildList {
                                    // Split into locals rather than inlining the two
                                    // conditionals around `to`: an if/else expression is
                                    // greedy, so the else branch swallows the infix `to`
                                    // and the whole thing types as Serializable.
                                    val advertisingLabel =
                                        if (state.isAdvertising) "Advertising" else "Not advertising"
                                    val advertisingColor =
                                        if (state.isAdvertising) Color(0xFF6BCB77) else Color.Gray
                                    add(advertisingLabel to advertisingColor)

                                    add("Subscribers: ${state.subscriberCount}" to Color.LightGray)
                                    if (state.isStreaming) {
                                        add("Streaming · ${state.packetsSent} pkts" to Color(0xFF4D96FF))
                                    }
                                },
                                note = state.error ?: state.lastEvent
                            )
                        }

                        item {
                            Chip(
                                modifier = Modifier.fillMaxWidth(),
                                label = { Text(if (state.isRunning) "Stop server" else "Start server") },
                                onClick = {
                                    val intent = Intent(context, GattServerService::class.java)
                                    if (state.isRunning) {
                                        intent.action = GattServerService.ACTION_STOP
                                        context.startService(intent)
                                    } else {
                                        // startForegroundService, not startService: the
                                        // service posts its notification immediately and
                                        // API 34+ requires that contract.
                                        context.startForegroundService(intent)
                                    }
                                },
                                colors = if (state.isRunning) {
                                    ChipDefaults.secondaryChipColors()
                                } else {
                                    ChipDefaults.primaryChipColors()
                                }
                            )
                        }
                    }
                }

                item {
                    Text(
                        text = "Service UUID ends 0001",
                        style = MaterialTheme.typography.caption3,
                        color = Color.Gray,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusBlock(lines: List<Pair<String, Color>>, note: String?) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        lines.forEach { (text, color) ->
            Text(
                text = text,
                style = MaterialTheme.typography.body2,
                color = color,
                textAlign = TextAlign.Center
            )
        }
        if (!note.isNullOrBlank()) {
            Text(
                text = note,
                style = MaterialTheme.typography.caption3,
                color = Color.Gray,
                textAlign = TextAlign.Center
            )
        }
    }
}
