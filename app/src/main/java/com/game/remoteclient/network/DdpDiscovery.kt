package com.game.remoteclient.network

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import com.game.remoteclient.models.PlayStationConsole
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

object DdpDiscovery {

    private const val TAG = "DdpDiscovery"

    private const val PS4_PORT = 987
    private const val PS5_PORT = 9302
    private const val PS4_VERSION = "00020020"
    private const val PS5_VERSION = "00030010"

    private const val MAX_RESPONSE_SIZE = 1024

    data class DdpTarget(val port: Int, val version: String)

    private val targets = listOf(
        DdpTarget(PS4_PORT, PS4_VERSION),
        DdpTarget(PS5_PORT, PS5_VERSION)
    )

    suspend fun discover(
        context: Context,
        timeoutMs: Long = 3000
    ): List<PlayStationConsole> = withContext(Dispatchers.IO) {
        val multicastLock = acquireMulticastLock(context)
        try {
            val wifiBroadcast = getWifiBroadcastAddress(context)
            if (wifiBroadcast != null) {
                Log.d(TAG, "Trying WiFi broadcast: ${wifiBroadcast.hostAddress}")
                val results = sendAndCollect(wifiBroadcast, timeoutMs)
                if (results.isNotEmpty()) return@withContext results
                Log.d(TAG, "No results from WiFi broadcast, falling back to 255.255.255.255")
            } else {
                Log.d(TAG, "Could not determine WiFi broadcast address, using 255.255.255.255")
            }

            val globalBroadcast = InetAddress.getByName("255.255.255.255")
            sendAndCollect(globalBroadcast, timeoutMs)
        } finally {
            if (multicastLock?.isHeld == true) multicastLock.release()
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireMulticastLock(context: Context): WifiManager.MulticastLock? {
        return try {
            val wifiManager = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
            wifiManager.createMulticastLock("reverse-of-power:discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not acquire multicast lock: ${e.message}")
            null
        }
    }

    private fun sendAndCollect(
        broadcastAddress: InetAddress,
        timeoutMs: Long
    ): List<PlayStationConsole> {
        val found = mutableMapOf<String, PlayStationConsole>()

        try {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                socket.soTimeout = timeoutMs.toInt()

                for (target in targets) {
                    val message = buildSrchMessage(target.version)
                    val packet = DatagramPacket(
                        message, message.size,
                        broadcastAddress, target.port
                    )
                    try {
                        socket.send(packet)
                        Log.d(TAG, "Sent SRCH to ${broadcastAddress.hostAddress}:${target.port}")
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to send SRCH to port ${target.port}: ${e.message}")
                    }
                }

                val deadline = System.currentTimeMillis() + timeoutMs
                val buf = ByteArray(MAX_RESPONSE_SIZE)

                while (System.currentTimeMillis() < deadline) {
                    val remaining = (deadline - System.currentTimeMillis()).toInt()
                    if (remaining <= 0) break
                    socket.soTimeout = remaining

                    try {
                        val responsePacket = DatagramPacket(buf, buf.size)
                        socket.receive(responsePacket)
                        val responseText = String(
                            responsePacket.data,
                            responsePacket.offset,
                            responsePacket.length
                        )
                        val senderIp = responsePacket.address.hostAddress ?: continue
                        val console = parseResponse(responseText, senderIp)
                        if (console != null) {
                            found[console.hostId] = console
                            Log.d(TAG, "Found ${console.hostType}: ${console.hostName} at $senderIp (${console.statusText})")
                        }
                    } catch (_: java.net.SocketTimeoutException) {
                        break
                    } catch (e: Exception) {
                        Log.w(TAG, "Error receiving response: ${e.message}")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Discovery failed: ${e.message}", e)
        }

        return found.values.toList()
    }

    private fun buildSrchMessage(version: String): ByteArray {
        return "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:$version\n".toByteArray()
    }

    fun parseResponse(data: String, senderIp: String): PlayStationConsole? {
        val lines = data.trim().split("\n").map { it.trim() }
        if (lines.isEmpty()) return null

        val statusLine = lines[0]
        if (!statusLine.startsWith("HTTP/")) return null

        val statusParts = statusLine.split(" ", limit = 3)
        if (statusParts.size < 2) return null
        val statusCode = statusParts[1].toIntOrNull() ?: return null

        val headers = mutableMapOf<String, String>()
        for (i in 1 until lines.size) {
            val colonIdx = lines[i].indexOf(':')
            if (colonIdx > 0) {
                val key = lines[i].substring(0, colonIdx).trim().lowercase()
                val value = lines[i].substring(colonIdx + 1).trim()
                headers[key] = value
            }
        }

        val hostId = headers["host-id"] ?: return null
        val hostType = headers["host-type"] ?: "Unknown"
        val hostName = headers["host-name"] ?: hostType

        return PlayStationConsole(
            hostName = hostName,
            hostId = hostId,
            hostType = hostType,
            ipAddress = senderIp,
            statusCode = statusCode,
            systemVersion = headers["system-version"],
            requestPort = headers["host-request-port"]?.toIntOrNull()
        )
    }

    @Suppress("DEPRECATION")
    private fun getWifiBroadcastAddress(context: Context): InetAddress? {
        return try {
            val wifiManager = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
            val dhcp = wifiManager.dhcpInfo ?: return null

            if (dhcp.ipAddress == 0) return null

            val ip = dhcp.ipAddress
            val mask = dhcp.netmask
            val broadcast = (ip and mask) or (mask.inv())

            val bytes = byteArrayOf(
                (broadcast and 0xFF).toByte(),
                (broadcast shr 8 and 0xFF).toByte(),
                (broadcast shr 16 and 0xFF).toByte(),
                (broadcast shr 24 and 0xFF).toByte()
            )
            InetAddress.getByAddress(bytes)
        } catch (e: Exception) {
            Log.w(TAG, "Could not get WiFi broadcast address: ${e.message}")
            null
        }
    }
}
