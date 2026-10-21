# Lumen สำหรับ Android (ต้นแบบ)

แอปฟังเพลงบน YouTube สำหรับมือถือ Android (Kotlin + Android WebView) ทำงานแบบเดียวกับ Lumen บน iPhone
บล็อกโฆษณาด้วยวิธีเดียวกับ Mac และ iPhone ([`../shared/LumenCore`](../shared/LumenCore)) แต่เขียนใหม่เป็น Kotlin
เพราะ Android ใช้โค้ด Swift ไม่ได้

## สิ่งที่ต้องมี
- **Android Studio** (`winget install Google.AndroidStudio`) ใช้ JDK ที่มาในตัว
- **Android SDK**: platform `android-36`, build-tools `36.0.0` และ emulator พร้อม system image ถ้าจะทดสอบโดยไม่มีมือถือจริง
  - SDK อยู่ที่ `%LOCALAPPDATA%\Android\Sdk` และ `local.properties` ชี้ไปที่นั่น (ไฟล์นี้ไม่เก็บใน git)
- **มือถือ Android** (ถ้ามี): เปิด Developer options → USB debugging แล้วเสียบสาย

## Build และติดตั้ง
ทุกคำสั่งรันจากโฟลเดอร์ `android` และตั้ง `JAVA_HOME` เป็น JDK ของ Android Studio ก่อน
(`C:\Program Files\Android\Android Studio\jbr`)
```
gradlew installDebug        # build และติดตั้งลงมือถือหรือ emulator ที่ต่ออยู่
gradlew testDebugUnitTest   # ทดสอบตัวบล็อกกับ ../shared/blocklist.txt
gradlew assembleRelease     # ได้ไฟล์ app/build/outputs/apk/release/app-release.apk
```
- ไม่มีมือถือ: เปิด emulator ที่สร้างไว้ด้วย `%LOCALAPPDATA%\Android\Sdk\emulator\emulator.exe -avd Lumen_API36`
  (Pixel 8, Android 16) หรือจาก Device Manager ใน Android Studio แล้วสั่ง `gradlew installDebug`
- ไฟล์ APK ติดตั้งแล้วใช้ได้ตลอด ไม่หมดอายุแบบ iPhone
- ตัว release ตอนนี้เซ็นด้วยกุญแจ debug ใช้ติดตั้งในเครื่องตัวเองได้ แต่ส่งขึ้น Play Store ไม่ได้
- ตอน build สคริปต์คัดลอก `../shared/blocklist.txt` และไฟล์ uBO Lite จาก `../windows/Extensions/uBOLite`
  (ชุดเดียวกับ `shared/copy-ubo.sh`) เข้าไปใน APK เอง

## ทำอะไรได้บ้าง
- เปิด YouTube เต็มจอ มือถือได้เว็บมือถือ (`m.youtube.com`)
- แถบด้านล่าง: ปุ่มย้อนกลับ ชื่อเว็บ และปุ่ม ⋯ (ไปข้างหน้า โหลดใหม่ หน้าแรก อัปเดต uBO และจำนวนโฆษณาที่หลุดมา)
  - ปุ่ม ⋯ มีจุดสีเขียวเมื่อมี uBO รุ่นใหม่ กดอัปเดตจากเมนูแล้วกด Restart แอปเปิดใหม่เองได้ (ต่างจาก iPhone)
- ปุ่ม back ของเครื่อง: ย้อนหน้าเว็บ ถ้าย้อนไม่ได้แล้ว Lumen จะไปอยู่เบื้องหลังโดยไม่ปิด เพลงจึงเล่นต่อ
- **ฟังต่อตอนปิดจอหรือสลับแอป**: แอปขึ้นเป็น foreground service พร้อมการแจ้งเตือนและปุ่มเล่น/หยุดบนหน้าจอล็อก
  - WebView ของ Android หยุดวิดีโอเองเมื่อหน้าต่างถูกซ่อน แอปจึงบอก WebView ว่าหน้าต่างยังเปิดอยู่ระหว่างที่เพลงเล่น
  - และหลอกหน้า YouTube ว่ายังเปิดดูอยู่ (สคริปต์เดียวกับ iPhone)
  - กดหยุดจากหน้าจอล็อกแล้วเพลงหยุดจริง ไม่เล่นต่อเอง
- **บล็อกโฆษณา** 4 ชั้นเหมือน Mac/iPhone:
  1. ดักทุก request (รวมของ service worker) เทียบกับ `blocklist.txt`
  2. scriptlet ของ uBO Lite ลบโฆษณาออกจากข้อมูลของเครื่องเล่น
  3. CSS ซ่อนช่องโฆษณา
  4. โฆษณาที่หลุดมา: ปิดเสียง เร่ง 16 เท่า และ**แตะปุ่มข้ามจริง** (iPhone ทำข้อนี้ไม่ได้)
- จำการล็อกอิน และส่งตัวเองเป็น Chrome เพื่อให้ล็อกอิน Google ได้
- ตัว debug: ดูข้างในหน้าเว็บได้จาก `chrome://inspect` ใน Chrome หรือ Edge บนคอม

## ต่างจาก iPhone
- Android WebView ไม่มี "world" แยกของสคริปต์ scriptlet ส่วน isolated ของ uBO และสคริปต์ของเราจึงรันใน world ของหน้าเว็บ
  (m.youtube.com ไม่มีกฎ isolated อยู่แล้ว)
- แถบด้านล่างไม่ย่อตอนเลื่อนจอ
- ยังไม่มีชุดทดสอบในแอป (`--selftest`) แบบ Mac/iPhone มีแค่ unit test ของตัวบล็อก
