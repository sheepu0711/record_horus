# Record Horus

Flutter app ghi âm, gắn nhãn local và tải file lên HorusDrive qua WebDAV.

## Tính năng

- Quản lý nhãn local: thêm, sửa, xoá.
- Ghi âm file `.m4a` trong thư mục app.
- Tên file sau khi dừng ghi âm có format:

```text
nhan_yyyymmdd_hhmmss_yyyymmdd_hhmmss.m4a
```

- Lưu danh sách bản ghi local bằng `SharedPreferences`.
- Lưu password HorusDrive bằng `flutter_secure_storage`.
- Sau khi dừng ghi âm, bản ghi được lưu trên máy, không tự upload.
- Chia sẻ trực tiếp file `.m4a` qua menu chia sẻ của điện thoại, không cần tài khoản HorusDrive.
- Tải lên HorusDrive khi bấm nút upload; bản ghi lỗi có thể bấm upload lại.
- Tạo/lấy link chia sẻ cho từng file âm thanh và copy link ngay trong app.
- Nghe lại bản ghi ngay trong app.
- Hiển thị sóng âm live khi đang ghi.
- Khoá font/leading ổn định hơn cho các máy MIUI/Xiaomi.

## Chạy app

```bash
flutter pub get
flutter run
```

Trong app, mở nút cài đặt ở góc phải để nhập:

- Server URL
- Kiểu xác thực: Basic hoặc Bearer
- Username
- Password / app password hoặc Bearer token
- Thư mục remote

Bấm `Kiểm tra` trong màn cài đặt để thử đăng nhập WebDAV trước khi upload.

Có thể build với cấu hình mặc định bằng `dart-define`:

```bash
flutter run \
  --dart-define=HORUS_SERVER_URL=https://drive.example.com \
  --dart-define=HORUS_USERNAME=your_user \
  --dart-define=HORUS_PASSWORD=your_password \
  --dart-define=HORUS_FOLDER=RecordHorus
```

Không commit password thật vào repo.

## Build iOS

Dự án có target `Runner` và extension `RecordingActivity` được nhúng sẵn trong app.
Cần macOS, Xcode 15 trở lên, Flutter 3.41 trở lên và CocoaPods. App hỗ trợ iOS 15+.

```bash
flutter pub get
cd ios
pod install
cd ..
open ios/Runner.xcworkspace
```

Trong Xcode, chọn cùng Apple Developer Team cho `Runner` và `RecordingActivity`.
Đổi bundle ID của cả hai target sang ID thuộc tài khoản của bạn; ID extension phải
bắt đầu bằng ID app (ví dụ `vn.company.recordhorus.RecordingActivity`). Sau đó:

```bash
flutter build ipa --release
```

Chỉ kiểm tra biên dịch, không ký app: `flutter build ios --release --no-codesign`.
Không cần thêm App Group hoặc push server cho Live Activity local.

### Ghi âm và điều khiển trên iOS

- Quyền microphone được hỏi khi bắt đầu ghi. Background Audio cho phép ghi khi
  khóa màn hình/chuyển app; plugin `record` quản lý audio session.
- iOS 17+: Live Activity trên màn hình khóa và Dynamic Island mở rộng có nút
  **Tạm dừng / Tiếp tục**, **Dừng / Lưu**, **Hủy bản ghi**.
- iOS 16.2–16.x: các nút trên Live Activity mở app để thực hiện lệnh, có thể cần
  mở khóa thiết bị. iOS 15–16.1: điều khiển trong app.
- **Dừng / Lưu** chỉ lưu file và danh sách local; có thể chia sẻ hoặc upload khi mở app.
  **Hủy bản ghi** xóa file đang ghi, không lưu/upload và không xóa bản ghi cũ.
- Khi dừng/hủy, Live Activity được gỡ. Thời gian trên Activity không tính phần
  tạm dừng. Lệnh của Activity cũ không tác động tới phiên ghi mới.
- Nếu tắt Live Activities trong Settings, app vẫn ghi âm nền; các nút điều khiển
  nằm trong app. Live Activity không thay thế quyền chạy audio nền.
- Sau khi tạm dừng/dừng, iOS có thể treo app. Lệnh trực tiếp giữ background task
  có giới hạn để xử lý lưu file. Chia sẻ/upload được thực hiện trong app;
  chưa triển khai upload nền `URLSession`.
- iOS có thể ngắt audio khi có cuộc gọi, đổi thiết bị âm thanh hoặc đóng cưỡng
  bức app. Không đảm bảo tiếp tục ghi sau khi người dùng vuốt tắt app. Khi plugin
  báo tạm dừng/tiếp tục, Activity được đồng bộ trạng thái.
- “Tiếp tục” trên Activity là tiếp tục **ghi âm**. Nghe lại file đã lưu vẫn dùng
  trình phát trong app như hiện tại; chưa có media controls cho nghe lại trên màn hình khóa.
- HorusDrive nên dùng HTTPS với chứng chỉ hợp lệ. Không tắt App Transport Security
  toàn cục; server HTTP/chứng chỉ tự ký cần cấu hình riêng trước khi dùng trên iOS.

Thiết kế dựa trên [Background Audio của Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
và [nút tương tác của Live Activity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).

### Kiểm tra trước khi phát hành iOS

Phần Flutter có kiểm tra tự động cho pause/resume, dừng và lưu file, hủy file,
lệnh từ Activity cũ và lỗi pause/stop (cho phép thử lại). Swift/Xcode và việc ghi âm nền phải kiểm tra
trên macOS/iPhone thật; test Flutter không chứng minh các nút native chạy khi máy khóa.

1. Cho phép/từ chối microphone; bắt đầu ghi với từng nhãn.
2. Ghi ít nhất 10 phút khi khóa màn hình/chuyển app; nghe lại toàn bộ file.
3. Pause từ Activity, chờ 2 phút, resume rồi stop; kiểm tra file, thời gian và
   danh sách local sau khi mở lại app.
4. Hủy từ Activity; xác nhận file tạm mất, danh sách và bản ghi cũ còn nguyên.
5. Bấm nhanh nhiều lần; thử cuộc gọi, Bluetooth/tai nghe và mất mạng khi upload.
6. Tắt Live Activities; kiểm tra ghi nền và điều khiển trong app vẫn hoạt động.
7. Kiểm tra Keychain giữ cấu hình đăng nhập sau restart; upload/lấy link/copy link,
   nghe lại, đổi/xóa nhãn và xóa bản ghi.
8. Build cả Debug và Release; kiểm tra iOS 16.2 fallback cùng iOS 17+ trên màn hình
   khóa và Dynamic Island, bao gồm resume sau khi app bị hệ thống treo.
