package com.longping

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.longping.core.ConfigException
import org.json.JSONArray
import org.json.JSONObject

/**
 * ReadableMap <-> org.json (the engine's currency) <-> WritableMap. JS numbers are doubles both
 * ways. NaN / Infinity cannot be represented in JSON and are rejected as INVALID_CONFIG naming the key.
 */
internal object ReactJson {
    fun toJson(map: ReadableMap?, path: String = ""): JSONObject {
        val out = JSONObject()
        if (map == null) return out
        val keys = map.keySetIterator()
        while (keys.hasNextKey()) {
            val key = keys.nextKey()
            out.put(
                key,
                when (map.getType(key)) {
                    ReadableType.Null -> JSONObject.NULL
                    ReadableType.Boolean -> map.getBoolean(key)
                    ReadableType.Number -> finite(map.getDouble(key), path + key)
                    ReadableType.String -> orNull(map.getString(key))
                    ReadableType.Map -> toJson(map.getMap(key), "$path$key.")
                    ReadableType.Array -> toJson(map.getArray(key), "$path$key")
                },
            )
        }
        return out
    }

    fun toJson(array: ReadableArray?, path: String): JSONArray {
        val out = JSONArray()
        if (array == null) return out
        for (i in 0 until array.size()) {
            out.put(
                when (array.getType(i)) {
                    ReadableType.Null -> JSONObject.NULL
                    ReadableType.Boolean -> array.getBoolean(i)
                    ReadableType.Number -> finite(array.getDouble(i), "$path[$i]")
                    ReadableType.String -> orNull(array.getString(i))
                    ReadableType.Map -> toJson(array.getMap(i), "$path[$i].")
                    ReadableType.Array -> toJson(array.getArray(i), "$path[$i]")
                },
            )
        }
        return out
    }

    // getString() is non-null before RN 0.80 and nullable after; this compiles cleanly against both.
    private fun orNull(value: String?): Any = value ?: JSONObject.NULL

    private fun finite(value: Double, key: String): Double {
        if (value.isNaN() || value.isInfinite()) throw ConfigException(key, "must be a finite number")
        return value
    }

    fun toWritableMap(obj: JSONObject): WritableMap {
        val out = Arguments.createMap()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            when (val v = obj.opt(key)) {
                null, JSONObject.NULL -> out.putNull(key)
                is Boolean -> out.putBoolean(key, v)
                is Number -> out.putDouble(key, v.toDouble())
                is String -> out.putString(key, v)
                is JSONObject -> out.putMap(key, toWritableMap(v))
                is JSONArray -> out.putArray(key, toWritableArray(v))
                else -> out.putString(key, v.toString())
            }
        }
        return out
    }

    fun toWritableArray(arr: JSONArray): WritableArray {
        val out = Arguments.createArray()
        for (i in 0 until arr.length()) {
            when (val v = arr.opt(i)) {
                null, JSONObject.NULL -> out.pushNull()
                is Boolean -> out.pushBoolean(v)
                is Number -> out.pushDouble(v.toDouble())
                is String -> out.pushString(v)
                is JSONObject -> out.pushMap(toWritableMap(v))
                is JSONArray -> out.pushArray(toWritableArray(v))
                else -> out.pushString(v.toString())
            }
        }
        return out
    }
}
