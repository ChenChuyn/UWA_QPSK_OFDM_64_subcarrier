# OFDM QPSK Audio Pager

Ứng dụng MATLAB nhắn tin một chiều qua ngõ âm thanh, hoạt động thành **hai chương trình riêng**:

- `ofdm_pager_rx` — chương trình nhận. Khi mở, tự chọn thiết bị mặc định, mở audio input và bắt đầu thu ngay; không cần bấm nút nhận. Chọn đúng thiết bị đầu vào trong danh sách nếu Windows không dùng đúng mặc định.
- `ofdm_pager_tx` — chương trình phát. Nhập văn bản ở độ dài tùy ý thực tế, nhấn **Gửi tin**; ứng dụng tự chia văn bản thành nhiều gói cố định, phát liên tiếp và cập nhật tiến độ.

Có thể mở từng chương trình trong hai phiên MATLAB riêng biệt. Để dùng cửa sổ chọn cả hai tab, chạy `ofdm_pager("rx")` hoặc `ofdm_pager("tx")`.

## Đặc tính

- Fs = 96 kHz; FFT = 1024; CP = 128 mẫu; fc = 33 kHz.
- 64 sóng mang từ 30 đến 36 kHz; 16 pilot, 48 sóng mang dữ liệu.
- QPSK với lặp bit, hai preamble Zadoff–Chu, ước lượng kênh, pilot tracking và CRC-16 theo khung.
- Gói có số thứ tự, ID tin và CRC toàn tin. Máy nhận ghép lại các gói, loại gói lặp và chỉ hiển thị tin khi ghép đủ, CRC toàn tin hợp lệ.
- Khung dài cố định; payload tối đa 80 byte/gói, phần dữ liệu tin nhắn tối đa 63 byte/gói. Một lần gửi hỗ trợ tối đa 4 MB UTF-8.
- Máy phát mặc định lặp mỗi gói 8 lần. Máy thu dùng audio block, buffer vòng và giải mã nền để không chặn luồng lấy mẫu.

## Thiết lập và vận hành

1. Cần MATLAB Audio Toolbox và Parallel Computing Toolbox.
2. Trong MATLAB thứ nhất, chạy `ofdm_pager_rx`. Đặt đúng thiết bị thu; ứng dụng bắt đầu nghe tự động khi mở.
3. Trong MATLAB thứ hai, chạy `ofdm_pager_tx`; chọn thiết bị phát, nhập hoặc dán nội dung dài, rồi bấm **Gửi tin**.
4. Chọn thiết bị Scarlett/line-in/loopback thực sự nối với nhau. `Default` chỉ đúng khi Windows đã cấu hình đúng cả hai thiết bị.
5. Bắt đầu với mức phát thấp (0.1–0.3). Nếu mức thu hiện trên cửa sổ RX thấp hoặc không khóa được, kiểm tra đầu vào, gain/AGC, dây nối và khả năng đáp tuyến của thiết bị.

Thiết bị, DAC/ADC, driver và đường tín hiệu phải thực sự truyền được 30–36 kHz ở 96 kHz. Nhiều sound card, microphone và loa giới hạn ở khoảng 20–24 kHz. Cấu hình sample rate 96 kHz không tự chứng minh thiết bị truyền được siêu âm. Không nối ngõ ra công suất/ampli trực tiếp vào ngõ vào máy tính.

Đây là liên kết một chiều: máy phát không nhận ACK và không thể tự yêu cầu gửi lại riêng gói bị mất. Lặp mỗi gói nhiều lần cùng CRC toàn tin tăng khả năng thu; nếu status báo tin chưa ghép xong, phát lại toàn bộ tin nhắn.

## Kiểm thử

```matlab
results = runtests("test_ofdm_pager.m");
assertSuccess(results);
```

Test kiểm tra băng 30–36 kHz, đồng bộ/ước lượng kênh, nhiễu đa đường, lệch tần số, lệch thời gian và chia/ghép văn bản Unicode dài qua nhiều khung.
