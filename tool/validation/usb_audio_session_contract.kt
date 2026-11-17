package dev.naominet.lazer

private class Connection(var fd: Int, var closes: Int = 0)
private fun state() = UsbAudioSessionState<Int, Connection>(
    fileDescriptor = { it.fd },
    disposeConnection = { it.closes++ },
)
private inline fun busy(block: () -> Unit) {
    try {
        block()
        error("The request should have been rejected with usb_busy")
    } catch (_: UsbAudioBusyException) {
    }
}
private inline fun contract(name: String, block: () -> Unit) {
    block()
    println("PASS $name")
}

fun main() {
    contract("cancel/reopen rejects the old permission result without consuming the replacement") {
        val sessions = state()
        var cancelledIntents = 0
        val old = sessions.requestPermission("DAC", 1)!!
        check(sessions.setPermissionCancellation("DAC", old.nonce) { cancelledIntents++ })
        check(sessions.cancelPermission("DAC") == listOf(1))
        val replacement = sessions.requestPermission("DAC", 2)!!
        check(old.nonce != replacement.nonce)
        check(sessions.completePermission("DAC", old.nonce).isEmpty())
        check(sessions.completePermission("DAC", null).isEmpty())
        check(sessions.pendingDeviceCount == 1 && sessions.pendingWaiterCount == 1)
        check(sessions.completePermission("DAC", replacement.nonce) == listOf(2))
        check(sessions.completePermission("DAC", replacement.nonce).isEmpty())
        check(cancelledIntents == 1)
    }
    contract("1000 duplicate requests retain only 32 waiters and preserve the accepted request") {
        val sessions = state()
        val request = sessions.requestPermission("DAC", 0)!!
        for (index in 1 until 32) check(sessions.requestPermission("DAC", index) == null)
        repeat(1000) { busy { sessions.requestPermission("DAC", 1000 + it) } }
        check(sessions.pendingDeviceCount == 1 && sessions.pendingWaiterCount == 32)
        check(sessions.completePermission("DAC", request.nonce) == (0 until 32).toList())
        check(sessions.pendingWaiterCount == 0)
    }
    contract("pending devices are capped at 8; cancellation releases capacity and invalidates replies") {
        val sessions = state()
        val requests = (0 until 8).map { sessions.requestPermission("DAC-$it", it)!! }
        repeat(1000) { busy { sessions.requestPermission("overflow-$it", it) } }
        check(sessions.pendingDeviceCount == 8 && sessions.pendingWaiterCount == 8)
        check(sessions.cancelPermission("DAC-3") == listOf(3))
        val replacement = sessions.requestPermission("DAC-3", 33)!!
        check(sessions.completePermission("DAC-3", requests[3].nonce).isEmpty())
        check(sessions.completePermission("DAC-3", replacement.nonce) == listOf(33))
        check(sessions.pendingDeviceCount == 7)
    }
    contract("invalid descriptors are closed before caching; a retry can open a healthy connection") {
        val sessions = state()
        val invalid = Connection(-1)
        try {
            sessions.openConnection("DAC") { invalid }
            error("An invalid descriptor was accepted")
        } catch (_: IllegalStateException) {
        }
        check(invalid.closes == 1 && sessions.connectionCount == 0)
        val good = Connection(42)
        check(sessions.openConnection("DAC") { good } === good)
        check(sessions.connectionCount == 1)
        good.fd = -1
        val reconnected = Connection(43)
        check(sessions.openConnection("DAC") { reconnected } === reconnected)
        check(good.closes == 1 && sessions.connectionCount == 1)
        sessions.closeConnection("DAC")
        sessions.closeConnection("DAC")
        check(reconnected.closes == 1 && sessions.connectionCount == 0)
    }
    contract("8 live connections are retained at capacity and repeated opens reuse the existing FD") {
        val sessions = state()
        val connections = (0 until 8).map { index ->
            Connection(index).also { connection ->
                check(sessions.openConnection("DAC-$index") { connection } === connection)
            }
        }
        var opens = 0
        repeat(1000) {
            check(sessions.openConnection("DAC-0") { opens++; Connection(99) } === connections[0])
            busy { sessions.openConnection("overflow") { opens++; Connection(100) } }
            busy { sessions.checkConnectionCapacity("overflow") }
        }
        check(opens == 0 && sessions.connectionCount == 8)
        check(connections.all { it.closes == 0 })
        sessions.closeConnection("DAC-0")
        sessions.openConnection("new") { Connection(101) }
        check(sessions.connectionCount == 8 && connections[0].closes == 1)
    }
    contract("an already-granted open and its delayed permission broadcast share one connection") {
        val sessions = state()
        val request = sessions.requestPermission("DAC", 1)!!
        sessions.requestPermission("DAC", 2)
        var opens = 0
        val first = sessions.openConnection("DAC") { opens++; Connection(42) }
        val waiters = sessions.completePermission("DAC", request.nonce)
        for (ignored in waiters) {
            check(sessions.openConnection("DAC") { opens++; Connection(43) } === first)
        }
        check(waiters == listOf(1, 2) && opens == 1 && sessions.connectionCount == 1)
    }
    contract("cancelAll retires all 256 waiters and their intents once, then permits fresh requests") {
        val sessions = state()
        var cancelledIntents = 0
        val requests = (0 until 8).map { device ->
            val request = sessions.requestPermission("DAC-$device", device * 32)!!
            sessions.setPermissionCancellation("DAC-$device", request.nonce) { cancelledIntents++ }
            for (waiter in 1 until 32) sessions.requestPermission("DAC-$device", device * 32 + waiter)
            request
        }
        check(sessions.cancelAllPermissions().sorted() == (0 until 256).toList())
        check(sessions.cancelAllPermissions().isEmpty())
        check(cancelledIntents == 8 && sessions.pendingDeviceCount == 0)
        val fresh = sessions.requestPermission("DAC-0", 300)!!
        for (old in requests) check(sessions.completePermission("DAC-0", old.nonce).isEmpty())
        check(sessions.completePermission("DAC-0", fresh.nonce) == listOf(300))
    }
    contract("a failed permission launch removes only its request; all accepted waiters can finish") {
        val sessions = state()
        val request = sessions.requestPermission("DAC", 1)!!
        sessions.requestPermission("DAC", 2)
        val other = sessions.requestPermission("other", 3)!!
        var retired = 0
        sessions.setPermissionCancellation("DAC", request.nonce) { retired++ }
        check(sessions.completePermission("DAC", request.nonce) == listOf(1, 2))
        check(retired == 1 && sessions.pendingDeviceCount == 1)
        check(sessions.completePermission("other", other.nonce) == listOf(3))
    }
    contract("closeAll attempts every connection even when one close throws") {
        val connections = (0 until 3).map { Connection(it) }
        val sessions = UsbAudioSessionState<Int, Connection>(
            fileDescriptor = { it.fd },
            disposeConnection = { it.closes++; if (it.fd == 0) error("close failed") },
        )
        connections.forEachIndexed { index, connection -> sessions.openConnection("$index") { connection } }
        val failure = runCatching { sessions.closeAllConnections() }.exceptionOrNull()
        check(failure is IllegalStateException && failure.message == "close failed")
        check(sessions.connectionCount == 0 && connections.all { it.closes == 1 })
        sessions.closeAllConnections()
        check(connections.all { it.closes == 1 })
    }
    println("USB audio session contracts: 9/9 passed")
}
