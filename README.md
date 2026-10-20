# MiniBrowser

Browser มินิมอล เบา ประหยัดเน็ต พร้อมตัวบล็อกโฆษณาในตัว ใช้กับ YouTube เป็นหลัก

| โฟลเดอร์ | คืออะไร | สถานะ |
|---|---|---|
| [`windows/`](windows) | แอพ Windows (C# + WPF + WebView2) และตัวติดตั้ง | ใช้งานได้ |
| [`macos/`](macos) | แอป Mac ชื่อ **Lumen** (Swift + AppKit + WKWebView) ไว้ฟังเพลงบน YouTube | ใช้งานจริงแล้ว (บล็อกโฆษณาด้วยสคริปต์ของ uBO) ยังไม่มีแท็บ |
| [`ios/`](ios) | แอพ iPhone (Swift + WKWebView) | วางแผนแล้ว ยังไม่ได้เริ่ม |
| [`shared/`](shared) | ของที่ใช้ร่วมกันทุกเครื่อง: โลโก้ (`Assets/`), `blocklist.txt` และ `LumenCore/` (ตัวบล็อกโฆษณาที่ Mac กับ iPhone/iPad ใช้ร่วมกัน) | — |

วิธี build และใช้งานของแต่ละเครื่องอยู่ใน README ของโฟลเดอร์นั้น
