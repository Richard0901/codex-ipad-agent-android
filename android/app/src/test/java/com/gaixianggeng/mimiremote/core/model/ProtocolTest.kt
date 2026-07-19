package com.gaixianggeng.mimiremote.core.model

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class ProtocolTest {
    private val json = Json { encodeDefaults = false }

    @Test
    fun `request omits params when absent`() {
        val encoded = json.encodeToString(JsonRpcRequest(7, "initialized"))
        assertEquals("""{"id":7,"method":"initialized"}""", encoded)
    }

    @Test
    fun `notification retains structured params`() {
        val message = JsonRpcNotification("turn/completed", JsonPrimitive("thread-1"))
        val decoded = json.decodeFromString<JsonRpcNotification>(json.encodeToString(message))
        assertEquals("turn/completed", decoded.method)
        assertEquals(JsonPrimitive("thread-1"), decoded.params)
    }
}
