## Mô tả

Repo gồm nhiều file bash shell mô tả nhiều vector tấn công DoS khác nhau. Mỗi script sẽ sử dụng một nhân CPU để chạy vì vậy hãy tính toán số thiết bị cần sử dụng tùy thuộc vào số lượng vector mà bạn muốn triển khai và quy mô mà bạn mong muốn. Vì những script này được tạo ra với mục đích học tập nên các kỹ thuật như giả mạo địa chỉ nguồn sẽ không được áp dụng.

## Các bước cài đặt

1. Tạo 1 file có đuôi .sh và copy nội dung script của tôi vào.
2. Cấp quyền thực thi cho file đó. Ví dụ: file tên temp.sh, mở terminal và dùng lệnh
”chmod +x temp.sh”
3. Chạy file với option -h, - -help hoặc help, sẽ hiện ra hướng dẫn sử dụng chi tiết tùy theo script, thường thì chỉ cần cài đặt các công cụ mà script yêu cầu, sẽ được ghi chi tiết trong từng script khác nhau.

## Luồng hoạt động và giải thích chi tiết công cụ

Công cụ sử dụng các tool được chạy bằng CLI, nên tôi sử dụng ngôn ngữ Bash để tối ưu tốc độ gọi câu lệnh, để đáp ứng được nhu cầu tính toán số học chính xác thì tôi sẽ kết hợp Python để tính toán.

Luồng hoạt động của công cụ:

1. Phân tích tham số đầu vào, các tham số như: địa chỉ IP mục tiêu, giao diện mạng sử dụng (đối với máy có nhiều card mạng), khoảng thời gian chạy công cụ, hệ số nén thời gian và cuối cùng là lựa chọn chế độ.
2. Kiểm tra xem đã cài đặt đủ các công cụ yêu cầu chưa, đã chạy công cụ bằng quyền admin chưa, đồng thời kiểm tra xem card mạng mà người dùng nhập có tồn tại không.
3.  Kiểm tra Python 3 đã được cài đặt chưa, nếu chưa thì có Python dự phòng chưa, nếu không có python thì sẽ tính toán bằng Bash calculator - kém chính xác hơn.
4. Tạo một file python động để tính toán các công thức toán học một cách chính xác - tạm gọi là máy tính python hoặc python calculator trong hướng dẫn này, bao gồm cả bắt chước hành vi theo giờ của con người và các pattern phổ biến trong DoS. File này được tạo khi chạy công cụ, file này chỉ là file được lưu trữ tạm thời trên đường dẫn temp, sẽ bị xóa ngay khi reboot, 
5. Kiểm tra kết nối bằng cách Ping đến target để kiểm tra xem có kết nối được đến target hay không.
6. Tùy theo chế độ người dùng chọn, chạy hàm khởi tạo lưu lượng theo mô hình đã chọn.
    1. Khời tạo TC QDisc với bộ lọc Token Bucket.
    2. Chạy lệnh hping3 hoặc siege, slowloris tùy thuộc vào loại kịch bản người dùng chạy. Các công cụ này sẽ chạy liên tục trong nền. 
    3. Vòng lặp chính, sẽ cập nhật TC rate theo mốc thời gian đã được tính bằng python calculator, vì TC QDisc chỉ có thể kiểm soát lưu lượng băng thông mạng từ đó đưa ra quyết định drop gói tin dư thừa, vì vậy toàn bộ số lượng packet sẽ được quy đổi thành băng thông và cập nhật lại TC rate. Lưu lượng và mốc thời gian, lượng packet sẽ được in ra màn hình và ghi vào file log chi tiết.
    4. Sau khi kết thúc thời gian chạy hoặc người dùng can thiệp làm dừng công cụ, sẽ xóa file máy tính python và clean hết các process mà công cụ đang chạy, tránh sai lệch về kết quả chạy lần sau và tràn bộ nhớ đệm.
