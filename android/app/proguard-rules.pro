# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Local Auth / Biometric
-keep class androidx.biometric.** { *; }

# App Model Classes
-keepattributes Signature
-keepattributes *Annotation*

# Google Play Core (fix R8 missing class)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }