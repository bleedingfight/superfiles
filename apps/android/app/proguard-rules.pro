# UniFFI/JNA: the generated bindings use reflection-free direct mapping,
# so only JNA's own classes need to be kept.
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
