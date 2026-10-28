# uniffi-generated bindings load libfilen_sdk_rs.so through JNA (reflection).
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.** { *; }
-dontwarn java.awt.*
