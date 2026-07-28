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
- Tự upload sau khi dừng ghi âm; bản ghi lỗi có thể bấm upload lại.
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
