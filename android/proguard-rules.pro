# Prevent obfuscation and stripping of the LineModel and CornerPointModel
-keep class com.abomis.camera_kit_plus.Classes.LineModel { *; }
-keep class com.abomis.camera_kit_plus.Classes.CornerPointModel { *; }

# Keep Gson annotations and serialized names
-keepattributes *Annotation*
-keepattributes Signature

# Prevent warnings from Gson
-dontwarn com.google.gson.**

# Keep all classes that use Gson serialization
-keep class com.google.gson.** { *; }
