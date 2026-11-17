package dev.naominet.lazer

import java.util.UUID

internal class UsbAudioBusyException(message: String) : IllegalStateException(message)

/** Main-thread state shared by the USB channel and permission receiver; no Android dependencies. */
internal class UsbAudioSessionState<Waiter, Connection>(
    private val fileDescriptor: (Connection) -> Int,
    private val disposeConnection: (Connection) -> Unit,
    private val maximumPendingDevices: Int = 8,
    private val maximumWaitersPerDevice: Int = 32,
    private val maximumConnections: Int = 8,
) {
    data class PermissionRequest(val nonce: String)

    private class Pending<Waiter>(val request: PermissionRequest, waiter: Waiter) {
        val waiters = mutableListOf(waiter)
        var cancelIntent: (() -> Unit)? = null
    }

    private val pending = mutableMapOf<String, Pending<Waiter>>()
    private val connections = mutableMapOf<String, Connection>()

    init {
        require(maximumPendingDevices > 0 && maximumWaitersPerDevice > 0 && maximumConnections > 0)
    }

    val pendingDeviceCount: Int get() = pending.size
    val pendingWaiterCount: Int get() = pending.values.sumOf { it.waiters.size }
    val connectionCount: Int get() = connections.size

    /** A null return joins the existing request; only the first waiter prompts Android. */
    fun requestPermission(id: String, waiter: Waiter): PermissionRequest? {
        val current = pending[id]
        if (current != null) {
            if (current.waiters.size >= maximumWaitersPerDevice) {
                throw UsbAudioBusyException("Too many pending requests for this USB DAC")
            }
            current.waiters.add(waiter)
            return null
        }
        if (pending.size >= maximumPendingDevices) {
            throw UsbAudioBusyException("Too many USB DAC permission requests")
        }
        val request = PermissionRequest(UUID.randomUUID().toString())
        pending[id] = Pending(request, waiter)
        return request
    }

    fun setPermissionCancellation(id: String, nonce: String, cancel: () -> Unit): Boolean {
        val current = pending[id] ?: return false
        if (current.request.nonce != nonce) return false
        current.cancelIntent = cancel
        return true
    }

    /** A late result must never consume a newer request for the same device path. */
    fun completePermission(id: String, nonce: String?): List<Waiter> {
        val current = pending[id] ?: return emptyList()
        if (nonce == null || current.request.nonce != nonce) return emptyList()
        pending.remove(id)
        return retire(current)
    }

    fun cancelPermission(id: String): List<Waiter> =
        pending.remove(id)?.let { retire(it) } ?: emptyList()

    fun cancelAllPermissions(): List<Waiter> {
        val cancelled = pending.values.toList()
        pending.clear()
        return cancelled.flatMap { retire(it) }
    }

    private fun retire(request: Pending<Waiter>): List<Waiter> {
        // Local invalidation is authoritative even if Android already sent its reply.
        request.cancelIntent?.let { runCatching(it) }
        request.cancelIntent = null
        return request.waiters.toList()
    }

    private fun validConnection(id: String): Connection? {
        val cached = connections[id] ?: return null
        if (runCatching { fileDescriptor(cached) >= 0 }.getOrDefault(false)) return cached
        connections.remove(id)
        disposeConnection(cached)
        return null
    }

    /** Fail before prompting where possible, and never evict a connection used by native audio. */
    fun checkConnectionCapacity(id: String) {
        if (validConnection(id) != null) return
        if (connections.size >= maximumConnections) {
            throw UsbAudioBusyException("Too many open USB DAC connections")
        }
    }

    fun openConnection(id: String, open: () -> Connection?): Connection {
        validConnection(id)?.let { return it }
        if (connections.size >= maximumConnections) {
            throw UsbAudioBusyException("Too many open USB DAC connections")
        }
        val connection = open() ?: throw IllegalStateException("Android could not open the USB DAC")
        try {
            check(fileDescriptor(connection) >= 0) { "Android returned an invalid USB descriptor" }
        } catch (error: Exception) {
            runCatching { disposeConnection(connection) }
            throw error
        }
        connections[id] = connection
        return connection
    }

    fun closeConnection(id: String) {
        connections.remove(id)?.let(disposeConnection)
    }

    fun closeAllConnections() {
        val closing = connections.values.toList()
        connections.clear()
        var firstError: Exception? = null
        for (connection in closing) {
            try {
                disposeConnection(connection)
            } catch (error: Exception) {
                if (firstError == null) firstError = error
            }
        }
        firstError?.let { throw it }
    }
}
