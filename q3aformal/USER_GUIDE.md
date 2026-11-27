# Q3AFORMAL R17 Preview User Guide

## 1. Mục đích và trạng thái hiện tại

Q3AFORMAL R17 Preview có gói cho Ubuntu 24.04 x86-64 và Windows x64. Gói Windows là bản R16 đã nghiệm thu Phase 0 đến Phase 3 theo phạm vi Windows. Gói Linux đã qua hồi quy dòng lệnh và 15 lượt benchmark Phase 2 trên máy ảo Ubuntu 24.04 ngoài Windows Subsystem for Linux (WSL). [Release R17 Preview](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview) · [Nghiệm thu Linux](https://github.com/nguyenquanicd/Q3AFORMAL/actions/runs/46002227798) · [Nghiệm thu Windows R16](evidence/r16/release-acceptance.json)

Bắt đầu tại [Cài đặt](#3-cài-đặt-và-build) và [Chạy thử và xem waveform](#chạy-thử-và-xem-waveform). Các ví dụ chuyên sâu dùng cú pháp PowerShell. Trên Linux, dùng `./prototype/bin/q3aformal-sourcecheck` với các lệnh dòng lệnh tương ứng.

Q3AFormal đọc mã RTL SystemVerilog và thuộc tính SystemVerilog Assertions (SVA) trong phạm vi một clock cạnh lên và dữ liệu hai giá trị. Ba chế độ kiểm chứng gồm Bounded Model Checking (BMC), k-induction và Property Directed Reachability (PDR). Công cụ phát lại phản ví dụ và cover witness trước khi công bố. Chứng minh k-induction và PDR đi kèm bằng chứng Deletion Resolution Asymmetric Tautology (DRAT). Các giới hạn ngữ nghĩa và giới hạn riêng từng engine nằm trong hồ sơ Phase 1. [Phạm vi Phase 1](specs/003-phase1-block-mvp/plan.md#supported-phase-1-language-profile)

Profile cơ sở `Q3A-P0-R0.9.1` quy định các cấu trúc RTL/SVA và ràng buộc cổng module phải khớp độ rộng. Ma trận bổ sung ghi phạm vi kiểm thử của manifest phiên bản 2, tiền xử lý, liên kết thuộc tính và các dạng timing hữu hạn. [Ma trận cơ sở](prototype/corpus/conformance-matrix.csv) · [Ma trận bổ sung Phase 1](prototype/corpus/phase1-conformance-additions.csv)

### Độ rộng và dấu của hằng số

Hằng số nhị phân, bát phân, thập phân và thập lục phân có độ rộng khai báo được kiểm tra ở các dạng gán và cây biểu thức ghi trong ma trận. Với phép gán trực tiếp sang đích rộng hơn, hằng unsigned được mở rộng zero và hằng signed được mở rộng dấu. Đích hẹp hơn giữ các bit thấp. Dùng ma trận để tra các tổ hợp toán tử, độ rộng và ngữ cảnh đã kiểm thử. [Bằng chứng RTL-006](prototype/corpus/results/t017-rtl006-sized-literal-conformance-2026-11-20.md)


### Lệnh chứng minh Phase 1

Lệnh `prove` chạy một thuộc tính bằng bounded model checking (BMC), k-induction hoặc Property Directed Reachability (PDR). Manifest phiên bản 2 cho phép chọn sẵn engine, thuộc tính và độ sâu. Manifest phiên bản 1 tiếp tục dùng được với các tùy chọn trên dòng lệnh. Kết quả là một đối tượng JavaScript Object Notation (JSON) trên standard output. Mã thoát `0` biểu thị chứng minh hoặc witness đã kiểm tra, `1` biểu thị chưa kết luận, `2` biểu thị lỗi thiết lập và `3` biểu thị lỗi engine. [Hướng dẫn lệnh Phase 1](specs/003-phase1-block-mvp/plan.md#initial-proof-interface) · [Cú pháp manifest](prototype/source/source_manager/README.md#manifest-format)

Manifest phiên bản 2 nhận `define NAME [TOKENS]` để đặt macro dạng đối tượng trước khi đọc RTL. Ví dụ, `define ENABLE_CHECKS` bật nhánh điều kiện và `define DATA_WIDTH (8 + 8)` đặt giá trị để mở rộng trong source. Dùng `include_dir "rtl/include"` để thêm thư mục tìm header sau thư mục của tệp đang include. Các đường dẫn phải nằm trong project. Bundle lưu môi trường macro và nội dung các header thực sự được dùng.

Khai báo tệp monitor và tệp `bind` bằng `property_source systemverilog "PATH"`. Dùng `bind leaf monitor u_checks (clk, data);` để gắn monitor vào mọi instance của module `leaf`. Dùng `bind top.g_lane[1].u_leaf monitor u_checks (clk, data);` để gắn vào đúng một instance. Monitor chỉ có cổng input và các cổng phải khớp độ rộng. Khi chạy `--property`, dùng tên thuộc tính sau elaboration, chẳng hạn `g_lane[1].u_leaf.u_checks.p_valid`.

Tệp SVA độc lập cũng dùng `property_source systemverilog "PATH"`. Có thể tham chiếu đường dẫn tương đối từ module top hoặc chỉ rõ `$root.<top>.`. Ví dụ, assertion trong tệp riêng có thể đọc tín hiệu nội bộ của lane 1.

```systemverilog
p_valid: assert property (@(posedge $root.top.clk)
    g_lane[1].u_leaf.valid |=> g_lane[1].u_leaf.ready);
```

Chạy `q3aformal-sourcecheck.exe properties .\project.q3a` để liệt kê assertion, assumption và cover sau elaboration, cùng tệp nguồn, dòng, clock và tín hiệu tham chiếu. Nếu lượt `prove` dùng `--parameter NAME VALUE`, truyền cùng giá trị cho `properties` để xem cùng cấu hình. `signals.rtl` lần ngược trạng thái lịch sử về tín hiệu được lấy mẫu. `signals.model` ghi các tham chiếu trực tiếp của mô hình, gồm trạng thái lịch sử do công cụ sinh. Cả hai danh sách dùng tên đã triển khai và được kiểm tra lại trong bundle mới.

Khai báo macro có tham số trong tệp SystemVerilog hoặc header. Macro hỗ trợ giá trị mặc định, lời gọi lồng nhau và dấu phẩy trong các cặp ngoặc của đối số. Để viết định nghĩa trên nhiều dòng, đặt dấu `\` ngay trước ký tự xuống dòng LF hoặc CRLF.

```systemverilog
`define IS_EXPECTED(VALUE, EXPECTED = 2'b10) \
    ((VALUE) == (EXPECTED))
// Invoke inside a property with the default EXPECTED value.
// `IS_EXPECTED({high_bit, low_bit})
```

Dùng hai dấu backtick liền nhau để ghép các mảnh trong macro. Ví dụ sau mở rộng lời gọi thành tên tín hiệu `ready_1`.

```systemverilog
`define LANE_READY(N) ready_``N
// `LANE_READY(1)
```

Tên header trong lệnh include có thể lấy từ macro. Kết quả mở rộng phải là đúng một đường dẫn tương đối trong dấu ngoặc kép. Công cụ tìm từ thư mục của tệp chứa lệnh include trước, sau đó theo thứ tự `include_dir` trong manifest.

```systemverilog
`define DESIGN_HEADER "config.svh"
`include `DESIGN_HEADER
```

Macro có thể tạo chuỗi đường dẫn trên một dòng bằng cặp dấu backtick và ngoặc kép. Ví dụ này chọn `config_1.svh`.

```systemverilog
`define CONFIG(N) `"config_``N.svh`"
`include `CONFIG(1)
```

Với mã thoát `2`, đọc trường `status` để phân biệt `SETUP_ERROR` cho cách gọi hoặc cú pháp không hợp lệ, `ELABORATION_ERROR` khi cấu hình thiết kế không dựng được mô hình, và `UNSUPPORTED` khi công cụ nhận diện tính năng ngoài phạm vi đã hỗ trợ. Khi lỗi có vị trí nguồn, mảng `diagnostics` cung cấp mã lỗi, mức độ, thông báo, tệp, dòng và cột.

Khi engine chạm giới hạn tài nguyên, `prove` trả `RESOURCE_LIMIT` với mã thoát `1`. Trường `resource_limit` cho biết giới hạn liên quan đến bộ nhớ, tìm kiếm hoặc xử lý bằng chứng. Khi PDR chạm độ sâu đã chọn mà chưa kết luận, trạng thái là `UNKNOWN`.

Dòng `Q3A_PDR_SEARCH_STATS` trên standard error ghi số lượt giải SAT và số lần dựng CNF. `state_bits` và `signal_bits` lần lượt là số bit trạng thái và tổng số bit tín hiệu trong vùng phụ thuộc dùng để tìm kiếm. `full_state_bits` và `full_signal_bits` mô tả mô hình đầy đủ dùng để kiểm tra tính khả thi ban đầu, chứng chỉ và witness.

Khi so sánh waveform của thuộc tính kéo theo giữa các engine, kiểm tra ý nghĩa mốc `candidate_frame`. Trong ca `|=>` đã kiểm thử, BMC và PDR đánh dấu mẫu đánh giá vế sau, còn witness cơ sở của k-induction đánh dấu mẫu bắt đầu nghĩa vụ. Trace lưu cả hai mẫu. [Ca đối chiếu giữa các engine](specs/003-phase1-block-mvp/plan.md#cross-engine-witness-agreement)

Với assertion, `properties[].vacuity` ghi riêng khả năng kích hoạt và phạm vi đã kiểm tra. `NOT_DETECTED_WITHIN_SCOPE` nghĩa là đã tìm thấy kích hoạt trong phạm vi đó. `INCOMPLETE` có thể đi cùng một lượt tìm hữu hạn chưa thấy kích hoạt hoặc một proof chưa kiểm tra kích hoạt. Trước khi tạo chứng chỉ, k-induction kiểm tra tính khả thi của phần đầu vết chạy. Nếu assumption mâu thuẫn trong phạm vi này, công cụ trả `INCONSISTENT_MODEL_OR_ASSUMPTIONS`.

Để kiểm tra riêng khả năng kích hoạt của một assertion, thêm `--check-activation` với engine PDR. Kết quả `ACTIVATION_UNREACHABLE` đi cùng chứng chỉ DRAT riêng và vacuity `DETECTED` trong phạm vi mô hình đã kiểm tra. `ACTIVATION_REACHED` cho biết công cụ đã phát lại một vết có đủ cửa sổ đánh giá. Dùng `--bundle-dir` để lưu waveform và `debug` để xem waveform cùng assertion gốc. Nếu hết độ sâu mà chưa kết luận, công cụ trả `UNKNOWN`. Khi mở lại chứng chỉ kích hoạt, dùng cùng tùy chọn. [Lệnh mẫu và phạm vi](specs/003-phase1-block-mvp/plan.md#feasibility-and-vacuity)

Đặt `--timeout-ms N` sau đường dẫn manifest và các tùy chọn `--parameter`, trước phần chọn engine hoặc tùy chọn riêng của engine. `N` là số nguyên từ 1 đến 86.400.000 mili giây. Khi một điểm kiểm tra phát hiện đã hết thời gian, lệnh trả `TIMEOUT`, mã thoát `1` và các trường `timeout_ms`, `elapsed_ms` và `timeout_stage`. Thời gian nạp đầu vào của lệnh `prove` được tính vào ngân sách. Công cụ kiểm tra thời hạn khi đọc danh sách tệp và xử lý các tệp nguồn, kể cả header. Một thao tác đọc, phân tích hoặc xuất bằng chứng có thể tiếp tục đến điểm kiểm tra kế tiếp hoặc tới khi hoàn thành thao tác xuất đã bắt đầu. Đây là thời hạn của lượt chứng minh, không phải cơ chế buộc tiến trình dừng đúng mili giây chỉ định.

Để hủy một lượt `prove` hoặc `prove-batch` trong terminal Windows, nhấn `Ctrl+C` hoặc `Ctrl+Break`. Q3AFORMAL dừng tại điểm kiểm tra và trả `CANCELLED` với mã thoát `1`. Với `prove`, tùy chọn `--run-record PATH` lưu kết quả JSON tại đường dẫn đã chọn, gồm nguyên nhân dừng và các bước đã hoàn tất. Khi chưa chọn đường dẫn, Q3AFORMAL tạo tệp `q3a-cancelled-<pid>-<id>.json` trong thư mục hiện tại và ghi vị trí vào standard error. Với `prove-batch`, nếu hủy khi đang nạp dự án chung, `batch.json` ghi `cancellation_stage: source_loading` và đánh dấu toàn bộ công việc là `NOT_RUN`. Nếu đã bắt đầu một công việc, công cụ lưu bản ghi của công việc đó và đánh dấu các công việc chưa chạy là `NOT_RUN`.

Để hủy từ một tiến trình khác, đặt `--cancel-file PATH` trước phần chọn engine rồi tạo tệp đó. Tệp rỗng cũng hợp lệ. Chọn tên mới cho mỗi lượt vì tệp đã tồn tại sẽ yêu cầu hủy ngay. Nếu chỉ chỉ định `--cancel-file`, hồ sơ mặc định nằm tại `PATH.result.json`. Q3AFORMAL yêu cầu thư mục đích đã tồn tại và giữ nguyên các hồ sơ có sẵn.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/counter4-fail.q3a --cancel-file .\job.cancel --run-record .\job.json --engine bmc --property p_wraps_to_zero --frames 10000
```

Trong cửa sổ PowerShell thứ hai, chạy `New-Item -ItemType File -Path .\job.cancel` để yêu cầu hủy. Mở lại hồ sơ của lượt bị dừng bằng lệnh sau.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe --verify-bundle .\job.json
```

Với hồ sơ `TIMEOUT` hoặc `CANCELLED`, lệnh kiểm tra cấu trúc và in trạng thái đã lưu, lý do dừng, bước hoàn tất và mã băm Secure Hash Algorithm 256-bit (SHA-256) của tệp. Mã thoát `0` cùng `STRUCTURE_VALID` xác nhận cấu trúc hồ sơ hợp lệ. Dòng `INTERRUPTION_METADATA_ONLY` cho biết phạm vi kiểm tra là thông tin về lượt dừng. Khi cần xác minh chứng minh hoặc witness, truyền đường dẫn thư mục bundle cho cùng lệnh.

Ví dụ dưới đây dùng manifest PDR có sẵn. Lệnh thứ hai dựng lại ba nghĩa vụ chứng minh và kiểm tra từng bằng chứng Deletion Resolution Asymmetric Tautology (DRAT).

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/pdr-pipeline.q3a --evidence-dir proof-pdr
.\prototype\bin\q3aformal-sourcecheck.exe verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir proof-pdr
```

Chọn thư mục chứng chỉ mới trong một thư mục cha đã có. Q3AFormal ghi tạm các bản ghi DRAT trên đĩa. Sau khi bộ kiểm tra chấp nhận cả ba nghĩa vụ, công cụ công bố cùng lúc invariant, ba truy vấn, ba tệp DRAT và `run-configuration.json` chứa cấu hình tìm kiếm ban đầu. Lệnh từ chối ghi đè nếu thư mục đích đã tồn tại.

Khi chứng chỉ PDR được ghi thành công, JSON của `prove` và từng tác vụ `prove-batch` có trường `certificate`. Trường này ghi đường dẫn tuyệt đối, mã định danh bản build và bộ kiểm tra, mã băm mô hình và mã băm SHA-256 của từng cặp truy vấn CNF và tệp DRAT. Dùng `verify-pdr` để dựng lại các truy vấn từ nguồn và kiểm tra lại chứng chỉ. Khi có `run-configuration.json`, lệnh đối chiếu cấu hình với mô hình và bằng chứng đã xác minh rồi in mã băm của tệp. Chứng chỉ cũ vẫn mở được khi thiếu tệp cấu hình.

Sau khi xác định thuộc tính và cấu hình tìm kiếm, BMC, k-induction và PDR ghi trường `run_configuration` trong kết quả JSON. Trường này ghi mã định danh bản build và nguồn, danh sách tệp và header được dùng cùng mã băm, tham số sau khi áp dụng ghi đè, macro, thứ tự giả định, clock, mục tiêu và chính sách reset. BMC ghi `transition_count`, k-induction ghi `induction_depth`, còn PDR ghi `maximum_depth` và `maximum_search_queries`. Các script PDR hiện có vẫn đọc được cấu hình qua `pdr_configuration`.

Hai trường `search_private_limit_bytes` và `search_physical_reserve_bytes` là ngưỡng bộ nhớ tìm kiếm tính bằng byte. Giá trị 0 nghĩa là ngưỡng tương ứng chưa được thiết lập. `elapsed_ms` ghi thời gian chạy. Dùng `--run-record <path>` để lưu cùng nội dung JSON ra tệp. Bản ghi gián đoạn `TIMEOUT` và `CANCELLED` dùng định dạng phiên bản 1. Nếu truy vấn đã được xác định trước khi dừng, `resolved_configuration` lưu mã băm manifest, dấu vân tay cấu hình đầy đủ, mục tiêu, độ sâu và các giới hạn của engine. Lệnh mở lại in `Q3A_RUN_RESOLVED_CONFIGURATION_SHA256` khi trường này hợp lệ. Hồ sơ cũ và lượt dừng sớm có thể thiếu trường này. Bản ghi ở bước `source_loading` có danh sách công việc hoàn tất rỗng và chưa có mã băm tập nguồn. Nếu engine và thuộc tính do manifest chọn, các trường đó chỉ xuất hiện sau khi công cụ đọc xong manifest.

PDR mặc định dùng tối đa 10.000 truy vấn SAT trong tìm kiếm. Thêm `--max-queries N` sau tùy chọn engine để đặt ngân sách cho một lượt `prove`. Ví dụ `--timeout-ms 60000 --engine pdr --property p_safe --max-queries 50000 --evidence-dir proof-pdr`. Thời hạn và chính sách bộ nhớ cùng áp dụng. Kết quả chạm ngân sách truy vấn trả `RESOURCE_LIMIT` với mã thoát 1.

PDR xử lý assertion, cover và assumption với độ trễ hữu hạn `##[m:n]`, khoảng lặp dương `[*m:n]`, phép kéo theo `|->` và `|=>`, và `$past` có điều kiện lịch sử hợp lệ. Assertion và assumption chờ hết cửa sổ của vế sau trước khi quyết định. Cover có thể báo tại mẫu đầu tiên khớp. Khoảng từ mẫu bắt đầu đến mẫu kết thúc tối đa 128 bước clock. Nếu các assumption khiến phần đầu của vết chạy không thể thỏa mãn trong giới hạn kiểm tra, lệnh trả `INCONSISTENT_MODEL_OR_ASSUMPTIONS`. Khi phát lại witness, bundle ghi rõ những nghĩa vụ ở cuối vết chạy chưa đủ mẫu để đánh giá. [Ví dụ SVA dùng khoảng](prototype/pdr-range-sequence.q3a) · [Ví dụ assumption nhiều mẫu](prototype/pdr-temporal-assumptions.q3a)

Khi tìm thấy cover witness và phát lại thành công, lệnh trả `COVERED`. Nếu chứng chỉ loại trừ mục tiêu trên mọi đường đi hợp lệ, lệnh trả `UNREACHABLE` với mã thoát `0`. Một lượt BMC không tìm thấy witness trong giới hạn trả `BOUNDED_COVER_MISS`.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/pdr-cover.q3a --evidence-dir cover-proof
.\prototype\bin\q3aformal-sourcecheck.exe verify-pdr prototype/pdr-cover.q3a --property p_never --evidence-dir cover-proof
```

### Chạy nhiều thuộc tính

Lệnh `prove-batch` chạy danh sách thuộc tính theo thứ tự trên cùng một manifest dự án. Ví dụ `prototype/batch-pipeline.q3b` gồm ba công việc trên cùng thiết kế.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove-batch prototype/pdr-pipeline.q3a --plan prototype/batch-pipeline.q3b --output-dir batch-results
```

Trong tệp kế hoạch, dòng `memory_mib` đặt trần bộ nhớ riêng của tiến trình Q3AFORMAL. Mỗi dòng `job` ghi mã công việc, engine, tên thuộc tính, độ sâu và giới hạn thời gian tính bằng mili giây. Công cụ chạy từng việc và áp dụng thêm giới hạn bộ nhớ do hệ thống hoặc biến môi trường đặt nếu giới hạn đó thấp hơn. Mỗi công việc có thư mục `job-<id>` riêng và `result.json`. Tệp `batch.json` giữ kết quả theo thứ tự cùng mã băm của kế hoạch, mã nguồn và bản build.

Nếu một tác vụ PDR cần ngân sách truy vấn riêng, dùng kế hoạch `Q3AFORMAL_BATCH 2` và thêm `max_queries N` ở cuối dòng tác vụ.

```text
Q3AFORMAL_BATCH 2
memory_mib 384
job proof-wide pdr p_safe 12 60000 max_queries 50000
job proof-default pdr p_safe 12 30000
```

Tác vụ PDR bỏ qua hậu tố này dùng mặc định 10.000 truy vấn. Ngân sách đã khai báo xuất hiện trong `batch.json`. Kết quả PDR có cấu hình tìm kiếm ghi ngân sách hiệu lực trong `result.json`. Kế hoạch `Q3AFORMAL_BATCH 1` vẫn đọc được.


Một công việc chưa kết luận hoặc bị từ chối vẫn được ghi lại và hàng đợi tiếp tục. Mã thoát của batch là mã cao nhất trong các việc đã chạy. Nếu hủy bằng `--cancel-file PATH`, batch trả `CANCELLED` và mã `1`, giữ kết quả đã có và đánh dấu những việc còn lại là `NOT_RUN`. Chọn tên thư mục đầu ra mới trong một thư mục cha đã tồn tại.

### Quét tham số trong bản thử nghiệm Phase 3

Dùng kế hoạch `Q3AFORMAL_BATCH 3` và thêm một hoặc nhiều mục `param NAME VALUE` ở cuối mỗi dòng `job`. Giá trị trên dòng ghi đè tham số cùng tên trong manifest cho riêng cấu hình đó.

```text
Q3AFORMAL_BATCH 3
memory_mib 768
job fixed induction p_hold 2 30000 param DROP_STALL 0
job faulty bmc p_hold 8 30000 param DROP_STALL 1
```

Chạy bằng `prove-batch`. Báo cáo giữ giá trị khai báo và giá trị thực tế giải quyết được cho từng job. Khi tiếp tục batch, công cụ dựng lại đúng cấu hình trước khi kiểm tra bằng chứng. Kết luận chỉ áp dụng cho các cấu hình liệt kê trong kế hoạch. [Hợp đồng quét tham số](specs/005-phase3-profile-expansion/parameter-sweep.md) · [Bằng chứng Windows](evidence/r-p3-sweep/qualification.json)

### Các profile trong R17 Preview

Hai gói cung cấp lệnh dòng lệnh cho bộ nhớ đồng bộ một clock, lịch cạnh đa clock, hàm lấy mẫu, thuộc tính liveness và logic bốn trạng thái theo phạm vi đã công bố. Giao diện waveform native chạy trên Windows. Cả hai nền tảng đều có thể tạo waveform HTML ngoại tuyến. [Gói phát hành](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview) · [Lệnh theo profile](docs/windows-development-preview.md)

### Đánh giá RTL tổ hợp với bốn trạng thái

Bật `-EnableDevelopmentFourState` khi build và khai báo `option profile Q3A-FOUR-STATE-DEVELOPMENT` trong manifest phiên bản 2. Dùng `dev-eval-four-state PROJECT --input NAME BITS` với mỗi cổng vào. Chuỗi bit dùng `0`, `1`, `x`, `z` và phải đúng độ rộng cổng. Lệnh trả giá trị của một bộ đầu vào cụ thể. [Phạm vi và ví dụ](specs/005-phase3-profile-expansion/four-state-expressions.md#evaluate-source-rtl)

Dùng `dev-prove-four-state PROJECT --expect OUTPUT BITS --evidence-dir DIR` để kiểm tra giá trị chính xác của cổng ra trên mọi tổ hợp đầu vào bốn trạng thái. Dùng `dev-verify-four-state` với cùng tham số để dựng lại truy vấn từ RTL và kiểm tra chứng chỉ. [Lệnh mẫu và ý nghĩa kết quả](specs/005-phase3-profile-expansion/four-state-expressions.md#prove-an-exact-output-value)

Với RTL tuần tự được hỗ trợ, thêm `--steps N` để kiểm tra đúng mẫu sau N lần cập nhật. Mẫu 0 dùng trạng thái khởi tạo `X`. Phản ví dụ có đầy đủ các mẫu đến thời điểm kiểm tra. [Ngữ nghĩa lấy mẫu và lệnh chạy](specs/005-phase3-profile-expansion/four-state-expressions.md#check-a-sampled-sequential-design)

Dùng `dev-prove-four-state PROJECT --property NAME --evidence-dir DIR --steps N` để kiểm tra chuỗi assertion hữu hạn hoặc phép kéo theo `|->`, `|=>` trong phạm vi N bước. Với r8, dùng `or` để nhận đường khớp từ một trong hai chuỗi, `and` để yêu cầu cả hai khớp và `intersect` để yêu cầu cùng điểm kết thúc. Kết quả phản ví dụ chỉ rõ mẫu kích hoạt và mẫu vi phạm. [Cú pháp và lệnh mẫu](specs/005-phase3-profile-expansion/four-state-expressions.md#check-a-named-sampled-assertion)

Khai báo `assume property` để giới hạn đầu vào hợp lệ. Nếu các giả định đã hoàn tất mâu thuẫn, kết quả là `INCONSISTENT`. Phản ví dụ còn phụ thuộc giả định qua biên được đánh dấu `WITNESS_PENDING_ASSUMPTION`. [Giả định và biên kiểm tra](specs/005-phase3-profile-expansion/four-state-expressions.md#constrain-the-sampled-environment)

Assertion hữu hạn hỗ trợ `$past`, `$stable`, `$changed`, `$rose` và `$fell` trên tín hiệu logic đóng gói và phép chọn bit hoặc lát có chỉ số hằng. `$past(signal, N)` nhận N từ 1 đến 128. Mẫu lịch sử chưa tồn tại có giá trị `X`. [Cú pháp và ngữ nghĩa](specs/005-phase3-profile-expansion/four-state-expressions.md#use-sampled-history)

Dùng cùng lệnh `dev-prove-four-state --property NAME` để tìm một chuỗi khớp với `cover property`. `COVERED` kèm trace JSON đã được phát lại, mẫu bắt đầu và mẫu hoàn tất chuỗi. Công cụ lưu các mẫu đầu vào trong `cover.q3awitness`. Dùng `dev-verify-four-state` với cùng project, property và số bước để mở lại bằng chứng. Chế độ này dựng lại trace từ RTL mà không chạy lại bộ giải SAT. `NOT_FOUND_WITHIN_BOUND` kèm chứng chỉ cho toàn bộ phạm vi mẫu đã chọn. [Ví dụ và cách kiểm tra bằng chứng](specs/005-phase3-profile-expansion/four-state-expressions.md#find-a-completed-cover-match)

Thêm `--save-witness` khi chạy `dev-prove-four-state` để lưu phản ví dụ thành `counterexample.q3awitness`. Mở lại bằng `dev-verify-four-state` với cùng tham số kiểm chứng. Công cụ dựng lại trace từ RTL và kiểm tra điểm vi phạm cùng các giả định đã hoàn tất. [Lệnh và định dạng bằng chứng](specs/005-phase3-profile-expansion/four-state-expressions.md#save-and-reopen-a-counterexample)

Thêm `--vcd FILE` để xuất dạng sóng của trace cover hoặc phản ví dụ. Dạng sóng giữ nguyên `X` và `Z` và đánh dấu các mẫu khớp hoặc vi phạm. Dùng `trace view-vcd FILE` để tạo tệp HTML xem ngoại tuyến. [Lệnh mẫu](specs/005-phase3-profile-expansion/four-state-expressions.md#inspect-a-replayed-waveform)

### Kiểm tra liveness trong bản build phát triển Phase 3

Bật `-EnableDevelopmentLiveness` khi build để dùng `dev-check-liveness`. Lệnh nhận hai tín hiệu RTL một bit biểu diễn yêu cầu và phản hồi. Có thể thêm `--justice SIGNAL` cho mỗi điều kiện phải xuất hiện vô hạn lần. Dùng `--evidence FILE` để lưu kết quả và `dev-verify-liveness` để xác minh lại bằng cùng project, các vị từ và giới hạn đồ thị. [Phạm vi hỗ trợ và lệnh mẫu](specs/005-phase3-profile-expansion/fair-cycle-liveness.md#save-and-reopen-evidence)

Với assertion SVA dùng `|-> s_eventually` hoặc `|=> s_eventually`, khai báo `option profile Q3A-LIVENESS-DEVELOPMENT` trong manifest phiên bản 2 rồi chọn assertion bằng `--property NAME`. Hai dạng khác nhau ở mẫu sớm nhất có thể thỏa phản hồi. [Cú pháp và ví dụ](specs/005-phase3-profile-expansion/fair-cycle-liveness.md#named-systemverilog-assertions)

Thêm `--vcd FILE` khi mở lại bằng chứng có vòng lặp để xuất dạng sóng RTL và các dấu mốc bắt đầu, kết thúc vòng. Dùng `trace view-vcd FILE` để tạo tệp xem HTML. [Xuất và xem dạng sóng](specs/005-phase3-profile-expansion/fair-cycle-liveness.md#inspect-the-loop-waveform)

### Hàm lấy mẫu trong profile phát triển Phase 3

Bản build riêng với `-EnableDevelopmentSampledValues` chấp nhận khai báo `option profile Q3A-SAMPLED-VALUE-DEVELOPMENT` trong manifest phiên bản 2. Trong assertion một clock, $stable và $changed so sánh toàn bộ giá trị đã lấy mẫu, còn $rose và $fell xét cạnh của bit thấp nhất. Khi lịch sử chưa đủ mẫu, điều kiện bảo vệ lịch sử của profile được áp dụng. [Cách build, lệnh chạy và giới hạn ngữ nghĩa](specs/005-phase3-profile-expansion/sampled-value-profile.md)

### Tiếp tục batch bị gián đoạn trong bản thử nghiệm Phase 2

Bản thử nghiệm Phase 2 có hai tùy chọn bổ sung cho `prove-batch`. Thêm `--checkpoint` khi khởi tạo vào thư mục mới. Sau khi gián đoạn, dùng cùng thư mục đầu ra và thay bằng `--resume`.

```powershell
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --checkpoint
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --resume
```

Giữ nguyên đường dẫn tuyệt đối của thư mục kết quả, mã nguồn, manifest, kế hoạch và bản build. Q3AFormal kiểm tra lại bằng chứng từ nguồn trước khi sử dụng kết quả đã ghi nhận. Job chưa hoàn tất hoặc chưa kết luận được chạy lại. Mỗi lần gọi giữ một thư mục `attempt-N` riêng và ghi các kết quả tái sử dụng bằng trường `reused`. Gói Windows Phase 1 vẫn dùng cách chạy batch được mô tả ở trên. [Đặc tả checkpoint](specs/004-phase2-subsystem/batch-scheduling-resume-review.md#serial-checkpoint-interface) · [Kết quả kiểm thử](evidence/r-p2-resume/qualification.json)

### Chạy batch song song trong bản thử nghiệm Phase 2

Thêm `--workers 2` vào lệnh khởi tạo hoặc tiếp tục batch có checkpoint. Mặc định là một worker. Bản thử nghiệm hỗ trợ từ hai đến tám worker trong chế độ song song.

```powershell
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --checkpoint --workers 2
```

Giá trị `memory_mib` trong kế hoạch bao gồm phần điều phối và các worker. Phần điều phối giữ tối thiểu 64 MiB hoặc một phần tư ngân sách, tùy mức nào lớn hơn. Phần còn lại chia đều theo MiB cho các worker, với ít nhất 32 MiB cho mỗi worker. Windows giới hạn bộ nhớ cam kết của từng cây tiến trình. Khi bộ nhớ vật lý còn ít, bộ điều phối hoãn nhận job mới. Kết quả vẫn được ghi theo thứ tự trong kế hoạch. [Thiết kế tài nguyên](specs/004-phase2-subsystem/batch-scheduling-resume-review.md#optional-parallel-workers) · [Kiểm thử Windows](evidence/r-p2-workers/qualification.json)

### Chứng minh hợp thành trong bản thử nghiệm Phase 2

Dùng `prove-composition` với kế hoạch `.q3c` để chứng minh các bảo đảm từ RTL theo thứ tự phụ thuộc, rồi kiểm tra thuộc tính cấp subsystem. Dùng `verify-composition` với cùng dự án, kế hoạch và thư mục chứng chỉ để dựng lại truy vấn và kiểm tra bằng chứng.

```powershell
.\q3aformal-sourcecheck.exe prove-composition design.q3a --plan plan.q3c --output-dir certificate
.\q3aformal-sourcecheck.exe verify-composition design.q3a --plan plan.q3c --evidence-dir certificate
```

Phạm vi hiện tại là một clock, thuộc tính an toàn theo từng mẫu và quy nạp một bước. `UNPROVEN` chỉ ra nghĩa vụ còn mở ở mô hình của khối. Có thể dùng lệnh `prove` trên mô hình toàn thiết kế và phát lại witness để kiểm chứng một vi phạm cụ thể. [Cú pháp kế hoạch và giới hạn](specs/004-phase2-subsystem/proof-composition-review.md#q3aformal-composition-plan-and-source-checks) · [Bằng chứng Windows](evidence/r-p2-composition-qualified/all-standalone-proofs.json)

### Kiểm tra tương đương trong bản thử nghiệm Phase 2

Dùng `check-equivalence` để so sánh hai dự án RTL với kế hoạch `.q3e`. Kế hoạch ghép mọi cổng theo hướng, độ rộng, dấu và phạm vi bit. Chọn `initial independent` để xét mọi cặp trạng thái đầu, `initial matched` cùng ít nhất một dòng `state` để ràng buộc cặp trạng thái ở mẫu 0, hoặc `reset <cổng bên tham chiếu> high|low` để quan sát từ sau cạnh reset đầu tiên. Với `initial matched`, phép so sánh đầu ra bắt đầu ở mẫu 0 và công cụ chứng minh riêng rằng quan hệ tiếp tục đúng ở các mẫu sau.

```powershell
.\q3aformal-sourcecheck.exe check-equivalence ref.q3a imp.q3a --plan pair.q3e --output-dir evidence
.\q3aformal-sourcecheck.exe verify-equivalence ref.q3a imp.q3a --plan pair.q3e --evidence-dir evidence
```

`EQUIVALENT` đi kèm chứng chỉ. `NOT_EQUIVALENT` đi kèm trace phát lại được, số mẫu sai lệch và giá trị ở hai đầu ra. Cả hai là kết quả đã xác minh và trả mã thoát 0. Phạm vi hiện tại là một clock, logic hai giá trị và so sánh đầu ra tại cùng một mẫu. [Cú pháp kế hoạch](specs/004-phase2-subsystem/memory-and-equivalence-review.md#q3aformal-equivalence-plan) · [Kết quả Windows](evidence/r-p2-equivalence/qualification.json)

Có thể thêm dòng `state y encoded invert` vào kế hoạch để yêu cầu hai thanh ghi tương ứng bù bit cho nhau. Dùng `equal` để yêu cầu bằng nhau. Công cụ kiểm tra quan hệ trạng thái trên mô hình từ nguồn bằng chứng chỉ riêng. `STATE_RELATION_VIOLATED` đi kèm trace và phân biệt sai lệch ở mẫu quan sát đầu tiên với sai lệch ở những mẫu sau. [Cú pháp quan hệ trạng thái](specs/004-phase2-subsystem/memory-and-equivalence-review.md#declared-state-correspondence)

Khi có sai lệch đã phát lại, công cụ tạo `paired-witness.vcd` cho đầu ra hoặc `state-witness.vcd` cho quan hệ trạng thái. Các tín hiệu nằm trong nhóm `shared`, `reference` và `implementation`. Tín hiệu `failure_sample` đánh dấu mẫu sai lệch. Dùng lệnh sau để tạo trang xem offline. [Kiểm thử waveform](evidence/r-paired-wave/qualification.json)

```powershell
.\q3aformal-sourcecheck.exe trace view-vcd evidence/paired-witness.vcd > paired-waveform.html
```

### Đọc waveform VCD

Để xem VCD ngoài dưới dạng HTML, chạy lệnh sau rồi mở tệp trong trình duyệt khi lệnh trả mã thoát 0.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe trace view-vcd input.vcd > external-waveform.html
```

Trang chạy ngoại tuyến, hỗ trợ tìm tín hiệu, chuyển theo mẫu và nhảy đến lần đổi giá trị. Chọn `Pin signal` để đối chiếu nhiều tín hiệu theo cùng cột timestamp. Bảng giữ các tín hiệu đã ghim khi bạn đổi bộ lọc, và tô sáng cột của mẫu hiện tại. Giá trị số được giữ giữa các mẫu và sự kiện chỉ xuất hiện ở mẫu có ghi sự kiện. Giá trị X/Z và timestamp gốc được giữ nguyên. Trang nạp dữ liệu VCD vào bộ nhớ của trình duyệt.


Dùng `trace import-vcd <file.vcd>` để đọc Value Change Dump (VCD) bên ngoài, hoặc thêm `--q3a-roundtrip` khi đọc lại VCD do Q3AFORMAL xuất. Lệnh giữ timestamp chính xác, timescale, tên tín hiệu và độ rộng. VCD bên ngoài giữ giá trị X/Z để hiển thị. Các tín hiệu dùng chung mã định danh được hiển thị dưới tên và phạm vi riêng nếu có cùng độ rộng và cùng loại dữ liệu sự kiện hoặc tín hiệu số. Chế độ `--q3a-roundtrip` yêu cầu mỗi khai báo có mã định danh riêng. Chỉ sử dụng dữ liệu xuất khi lệnh trả mã thoát 0. [Cú pháp và phạm vi hỗ trợ](specs/003-phase1-block-mvp/plan.md#vcd-import)

### Đọc trace theo cửa sổ thời gian

Bundle mới chứa `trace.q3atrace` cho witness đã replay. Dùng `trace window <file.q3atrace> --first N --last N --signal NAME` để lấy giá trị và các lần thay đổi trong khoảng mẫu đã chọn. Chạy `--verify-bundle` khi cần xác minh trace theo witness gốc. [Định dạng trace và cú pháp](specs/003-phase1-block-mvp/plan.md#indexed-witness-traces)

VCD và HTML mặc định hiển thị cổng top-level, clock, trạng thái và các tín hiệu liên quan tới thuộc tính, giả định hoặc điều khiển tuần tự. Lặp `--trace-signal NAME` để thêm tín hiệu bằng tên phân cấp, hoặc dùng `--trace-all` để xuất toàn bộ. Bundle lưu cấu hình hiển thị trong `trace/capture.json` và giữ witness đầy đủ cho replay. [Cấu hình chọn tín hiệu](specs/003-phase1-block-mvp/plan.md#waveform-signal-selection)

Bundle k-induction có `base.trace.q3atrace` cho phản ví dụ bước cơ sở và `step.trace.q3atrace` cho countermodel bước quy nạp khi từng nghĩa vụ tương ứng có witness đã replay. Cả hai dùng được với lệnh `trace window`. [Trace của k-induction](specs/003-phase1-block-mvp/plan.md#indexed-induction-witnesses)

Các lệnh `trace window`, `trace import-vcd` và `trace view-vcd` hỗ trợ đường dẫn dài trên Windows. Đặt đường dẫn trong dấu ngoặc kép nếu có khoảng trắng.

### Mở giao diện debug bốn khung

Trên Windows, chạy `q3aformal-sourcecheck.exe gui <bundle-directory>` để mở cửa sổ waveform từ bundle có witness. Công cụ xác minh lại witness và tái tạo mô hình từ mã nguồn lưu trong bundle trước khi hiển thị. Dùng các nút điều hướng để đổi vùng xem hoặc trở về mẫu witness. Chọn tín hiệu để mở dòng RTL tương ứng, hoặc chọn một dòng RTL và bấm **Show signal**. **Save** và **Open** lưu và mở trạng thái JSON cho cùng bundle và trace. **Prev change** và **Next change** chuyển tới mẫu đổi giá trị của tín hiệu đang chọn. **Radix** lần lượt hiển thị giá trị ở hệ thập lục phân, nhị phân và thập phân không dấu. Dùng **Mark/clear** và **Next marker** để đánh dấu và duyệt các mẫu. Nhập tên nhóm rồi bấm **Save group** để lưu bộ tín hiệu đang hiển thị. **Use group** áp dụng nhóm đã lưu. Phiên JSON giữ viewport, marker và nhóm của cùng bundle.

Với witness của k-induction, dùng `gui <bundle-directory> --obligation base` hoặc `gui <bundle-directory> --obligation step` để chọn phần bằng chứng cần xem. Có thể truyền `--group LABEL SIGNAL` nhiều lần để tạo nhóm tín hiệu khi mở cửa sổ. Dùng `--reset SIGNAL high|low` để tô các khoảng reset đang có hiệu lực, kể cả khi tín hiệu reset không nằm trong nhóm đang hiển thị.

Trên Windows và Linux, chạy `debug <bundle-directory>` và lưu đầu ra thành HTML để mở trang offline. Trang mở tại mẫu witness và liên kết tín hiệu với dòng nguồn trong bundle. Đính kèm tệp `.q3atrace` để xem thêm mẫu hoặc tín hiệu. Có thể lưu và khôi phục phiên debug cho cùng bundle. [Cú pháp và phạm vi trình debug](specs/003-phase1-block-mvp/plan.md#four-panel-debug-view)

Dùng **Previous change** và **Next change** để tới mẫu gần nhất có tín hiệu đang chọn đổi giá trị.

Sau khi đính kèm trace, chọn **Index changes** để lập chỉ mục điểm đổi cho các tín hiệu đang chọn. Trạng thái hiển thị số khối đã xử lý. **Stop indexing** hoặc thao tác điều hướng waveform sẽ dừng tác vụ. Lần chạy lại dùng các mục đã hoàn tất. Chỉ mục sử dụng tối đa 32 KiB dữ liệu cho mỗi trace đính kèm và tách riêng khỏi bộ nhớ đệm cửa sổ đang xem.

Thêm `--reset SIGNAL high|low` để tô vùng reset có hiệu lực theo cực tính đã cấu hình. Dùng `--group LABEL SIGNAL` để tạo nhóm lọc, chẳng hạn nhóm tín hiệu APB hoặc CSR.

Dùng hai nút mũi tên để dịch cửa sổ hiển thị và giữ nguyên con trỏ. **Zoom (frames)** chọn 16, 32 hoặc 64 mẫu trong cửa sổ. **Mark cursor** đánh dấu mẫu hiện tại. Dùng **Go to marker** hoặc **Remove marker** để mở hoặc xóa mốc đã chọn. **Save session** lưu marker, vị trí cửa sổ, con trỏ, nhóm và tín hiệu cho cùng bundle. Khi mở lại phiên, đính kèm tệp `.q3atrace` nếu cửa sổ nằm ngoài phần waveform đã nhúng.

## 2. Yêu cầu môi trường

| Hệ điều hành | Môi trường chạy bản đóng gói | Xem waveform |
| --- | --- | --- |
| Windows x64 | PowerShell và Python 3 nếu dùng trình cài đặt | Cửa sổ native bằng `gui` hoặc HTML ngoại tuyến |
| Ubuntu 24.04 x86-64 | Thư viện hệ thống GNU C/C++ và Python 3 nếu dùng trình cài đặt | HTML ngoại tuyến trong trình duyệt |

Gói phát hành tích hợp bộ giải Boolean satisfiability (SAT). Tùy chọn build từ mã nguồn cần trình biên dịch C++17. Trên Linux, hỗ trợ đã được xác minh cho Ubuntu 24.04 x86-64.

## 3. Cài đặt và build

### Cài đặt bằng trình cài tự nhận diện hệ điều hành

1. Tải [install.py](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/install.py) và [INSTALL_SHA256SUMS](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/INSTALL_SHA256SUMS) từ [R17 Preview](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview).
2. Tải [ZIP Windows x64](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-windows-x64-development-preview-r16.zip) hoặc [gói Ubuntu 24.04 x86-64](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-linux-x64.tar.gz) vào cùng thư mục với hai tệp trên. Tên ZIP Windows có hậu tố `r16` vì R17 Preview sử dụng đúng gói Windows R16 đã nghiệm thu.
3. Mở terminal tại thư mục tải về và chạy lệnh phù hợp. Trình cài đặt nhận diện hệ điều hành và kiến trúc, kiểm tra mã băm SHA‑256 rồi giải nén.

**Windows PowerShell**

~~~powershell
python install.py
~~~

Nếu dùng Python Launcher, có thể chạy `py -3 install.py`.

**Linux**

~~~sh
python3 install.py
~~~

Windows mặc định cài vào `%LOCALAPPDATA%\Q3AFORMAL`. Linux mặc định cài vào `~/.local/opt/q3aformal`. Dùng `--prefix PATH` để chọn thư mục đích mới hoặc `--assets-dir PATH` để chỉ định nơi chứa các tệp tải về. Nếu thư mục đích đã tồn tại, hãy chọn một thư mục mới.

### Cài thủ công

Đối chiếu SHA‑256 với dòng tương ứng trong `INSTALL_SHA256SUMS`. Trên Windows dùng `Get-FileHash -Algorithm SHA256` rồi `Expand-Archive`. Trên Linux dùng `sha256sum` rồi `tar -xzf q3aformal-linux-x64.tar.gz -C PATH` với `PATH` là thư mục đích đã tạo. Sau khi giải nén, hai executable trong `prototype/bin` chạy trực tiếp.

### Chạy thử và xem waveform

Chạy từ thư mục cài đặt hoặc thư mục đã giải nén, nơi có thư mục `prototype`. Thay đường dẫn ở dòng đầu nếu đã chọn `--prefix` hoặc giải nén thủ công. Chọn tên thư mục đầu ra mới khi chạy lại.

**Windows PowerShell**

~~~powershell
Set-Location "$env:LOCALAPPDATA\Q3AFORMAL"
$q3a = '.\prototype\bin\q3aformal-sourcecheck.exe'
& $q3a --version
& $q3a prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
& $q3a verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
& $q3a prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir cover-witness
& $q3a --verify-bundle cover-witness --require-source-model
& $q3a gui cover-witness
~~~

Cửa sổ native mở tại mẫu witness. Để tạo tệp HTML ngoại tuyến, chạy `& $q3a debug cover-witness > cover-witness.html` trong PowerShell 7.4 trở lên và mở tệp bằng trình duyệt.

**Linux**

~~~sh
cd "$HOME/.local/opt/q3aformal"
q3a=./prototype/bin/q3aformal-sourcecheck
"$q3a" --version
"$q3a" prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
"$q3a" verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
"$q3a" prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir cover-witness
"$q3a" --verify-bundle cover-witness --require-source-model
"$q3a" debug cover-witness > cover-witness.html
~~~

Mở `cover-witness.html` bằng trình duyệt, hoặc sao chép tệp sang máy có trình duyệt nếu Linux chạy qua terminal từ xa. Nếu đã có tệp Value Change Dump (VCD) riêng, dùng `& $q3a trace view-vcd input.vcd > input.html` trên PowerShell 7.4 trở lên hoặc `"$q3a" trace view-vcd input.vcd > input.html` trên Linux.

Ví dụ an toàn trả `PROVEN` và lưu chứng chỉ vào `safety-proof`. Ví dụ cover trả `COVERED`. Lệnh xác minh bundle trả `Q3A_BUNDLE_STATUS REVALIDATED` sau khi xác minh lại mô hình từ nguồn và phát lại witness. [Điều hướng waveform và phiên debug](#mở-giao-diện-debug-bốn-khung)

### Kiểm thử gói Linux bằng GitHub Actions

Workflow tải lại gói R17 Preview công khai, cài vào thư mục mới trên máy ảo Ubuntu 24.04 x86-64 ngoài WSL, chạy hai ví dụ ở trên và kiểm tra waveform HTML bằng trình duyệt chạy nền. Workflow dùng gói phát hành đã đóng gói và kiểm tra SHA-256 trước khi cài.

1. Đăng nhập GitHub bằng tài khoản có quyền ghi vào repo. Mở tab **Actions** và chọn [Q3AFORMAL R17 Ubuntu Release Audit](https://github.com/nguyenquanicd/Q3AFORMAL/actions/workflows/r17-ubuntu-release-audit.yml).
2. Bấm **Run workflow**, chọn nhánh `main`, rồi bấm **Run workflow** lần nữa. Workflow dùng sẵn release `r17-preview`. Có thể bấm lại để tạo lượt chạy mới.
3. Mở lượt chạy mới trong danh sách. Chọn job **Verify public R17 assets on Ubuntu 24.04 x86-64** để xem từng bước và log.
4. Khi lượt chạy kết thúc, mở **Summary**, cuộn đến **Artifacts** và tải `r17-release-audit-ubuntu-24.04`. Giải nén tệp ZIP, đọc `verdict.json` để xem kết quả, rồi mở `cover-witness.html` và `input.html` trong trình duyệt để xem waveform cover và VCD. ZIP cũng chứa `input.vcd` cùng log đầu ra. Nếu một bước thất bại, mở log của bước đó và tải bằng chứng đã thu được nếu có.

### Build từ mã nguồn

Để build trên Windows, dùng PowerShell 7 và MinGW-w64 hỗ trợ C++17. Từ thư mục `q3aformal` trong repo, chạy `.\prototype\source\source_manager\build.ps1` và `.\prototype\checker\build.ps1`. Nếu `g++.exe` nằm ngoài `PATH`, truyền tùy chọn `-Compiler '<path-to-g++.exe>'`. Để build và chạy hồi quy trên Linux, dùng CMake 3.20 trở lên, trình biên dịch C++17 và Python 3. [Build trên Windows](../README.md#windows-build-from-source) · [Build trên Linux](docs/linux.md#build-and-validate)

### macOS 15 trên Apple silicon và Intel

Repo có bản build phát triển cho macOS 15. Dùng CMake để build từ mã nguồn hoặc tải artifact phù hợp với kiến trúc của máy từ workflow macOS. Giải nén artifact, giữ `install.py`, `INSTALL_SHA256SUMS` và gói `.tar.gz` trong cùng thư mục rồi chạy `python3 install.py`. Dùng các lệnh Linux trong mục chạy thử ở trên và mở waveform bằng `open cover-witness.html`. [Hướng dẫn build và chạy macOS](docs/macos.md) · [Workflow macOS](https://github.com/nguyenquanicd/Q3AFORMAL/actions/workflows/macos-cli.yml)

### Thử nghiệm kiểm chứng bộ nhớ ở bản phát triển

Bản build với `-EnableDevelopmentMemory` bổ sung `dev-prove-memory` và `dev-verify-memory` cho cấu hình bộ nhớ đồng bộ một clock đang thử nghiệm. Cần một manifest dự án, tên assertion, thư mục bằng chứng và giới hạn số ô nhớ. Bản build phát triển hiện công bố thư mục bằng chứng sau khi cả ba chứng chỉ đã được kiểm tra. Khi mở lại kết quả, công cụ dựng lại mô hình từ mã nguồn rồi xác minh riêng chứng chỉ đọc, ghi và thuộc tính chính. [Cách build và chạy thử](specs/004-phase2-subsystem/memory-and-equivalence-review.md#development-command-line)

Dùng `--activation-frames N` với lệnh chứng minh hoặc mở lại chứng chỉ để kiểm tra assertion có mẫu đánh giá trong N bước chuyển trạng thái. Kết quả phân biệt mẫu đã phát lại, mẫu còn phụ thuộc giả định tương lai và trường hợp chưa tìm được mẫu trong giới hạn. Khi các giả định mâu thuẫn trong phạm vi đã kiểm tra, công cụ trả `INCONSISTENT`. [Kiểm tra kích hoạt assertion](specs/004-phase2-subsystem/memory-and-equivalence-review.md#assumption-feasibility-and-assertion-activation)

Thêm `--diagnose-range` khi chạy `dev-prove-memory` để yêu cầu tìm vị trí đọc hoặc ghi vượt biên. Khi phát lại được trace, công cụ trả tệp, dòng, địa chỉ và khoảng hợp lệ tại mẫu lỗi đầu tiên của trace. [Chi tiết chẩn đoán](specs/004-phase2-subsystem/memory-and-equivalence-review.md#range-diagnostics) Dùng `--range-trace FILE` để lưu trace và `dev-verify-memory-range` để mở lại bằng đúng manifest cùng thuộc tính. [Lệnh lưu và mở lại](specs/004-phase2-subsystem/memory-and-equivalence-review.md#save-and-reopen-a-range-trace) Dùng `dev-gui-memory-range` để xem dạng sóng và mã RTL tại mẫu lỗi trên Windows. [Lệnh mở giao diện](specs/004-phase2-subsystem/memory-and-equivalence-review.md#native-windows-range-viewer)

### Thử nghiệm kiểm chứng nhiều miền clock

Bản build riêng với `-EnableDevelopmentEventMask` cung cấp `dev-check-events` và `dev-verify-events`. Các lệnh lấy manifest dự án, tên thuộc tính, thư mục lưu bằng chứng và giới hạn số bước toàn cục khi chạy kiểm tra. Trace ghi cả bước toàn cục lẫn mẫu riêng theo miền clock. Thêm hai lệnh `dev-prove-events` và `dev-verify-event-proof` để chứng minh an toàn theo mô hình cạnh đã chọn và xác minh lại chứng chỉ. Công cụ giữ trạng thái chưa kết luận khi trace vẫn còn nghĩa vụ giả định. [Cách build và chạy thử](specs/004-phase2-subsystem/multi-clock-scheduling-review.md#development-event-commands)

Để mở trace đa clock trong giao diện Windows, dùng bản build phát triển và chạy lệnh dưới đây với đúng manifest và tên thuộc tính của lần tạo trace. Giao diện kiểm tra trace trước khi mở và hiển thị bước toàn cục, mẫu riêng của từng clock hoặc trạng thái không có cạnh ở bước đang chọn.

```powershell
& $exe dev-gui-events project.q3a --property c_hit --evidence-dir event-witness
```

## 4. Chuẩn bị project RTL

Các lệnh project nhận một manifest `.q3a`. Manifest xác định top module, parameter override tùy chọn và danh sách source theo thứ tự đọc.

Ví dụ thư mục project:

```text
my_design/
  project.q3a
  rtl/
    counter.sv
    top.sv
```

Nội dung `my_design/project.q3a`:

```text
Q3AFORMAL_PROJECT 1
top my_top
parameter WIDTH 8
source "rtl/counter.sv"
source "rtl/top.sv"
```

Quy tắc manifest:

- Dòng đầu tiên không trống hoặc comment phải là `Q3AFORMAL_PROJECT 1`.
- Khai báo đúng một `top IDENTIFIER`.
- Có thể khai báo `parameter NAME VALUE` nhiều lần để override parameter. Không được khai báo trùng tên.
- Cần ít nhất một dòng `source "relative/path.sv"`; thứ tự source được giữ nguyên.
- Dòng trống và dòng bắt đầu bằng `#` được bỏ qua.
- Source path tính từ thư mục chứa manifest. Không dùng đường dẫn tuyệt đối, thành phần `..`, file không tồn tại, hoặc đường dẫn trỏ ra ngoài thư mục project.
- Không liệt kê cùng một file nhiều lần.
- Input hiện tại là Verilog/SystemVerilog trong subset parser hỗ trợ. Manifest phiên bản 2 dùng được object-like macro và include với đường dẫn tương đối. VHDL và các cấu trúc SystemVerilog ngoài profile còn ngoài phạm vi.

Có thể dùng manifest mẫu trong repository: `prototype/counter4.q3a`.

## 5. Các lệnh chạy

Trong PowerShell, đặt biến cho executable để các ví dụ ngắn hơn:

```powershell
$q3a = '.\prototype\bin\q3aformal-sourcecheck.exe'
```

### 5.1 Đọc manifest và tạo input identity

```powershell
& $q3a .\prototype\counter4.q3a
```

Output gồm profile, top module, parameter, SHA-256 của toàn bộ input và SHA-256 của từng source. Lệnh này chỉ xác nhận project input đã được đọc; nó không parse hoặc prove RTL.

### 5.2 Tokenize hoặc parse một source

```powershell
& $q3a --lex .\prototype\corpus\source-model-vectors\counter4_pass.sv
& $q3a --parse .\prototype\corpus\source-model-vectors\counter4_pass.sv
```

- `--lex` in token, loại token và vị trí trong source.
- `--parse` kiểm tra cú pháp subset parser và in module cùng số lượng construct nhận diện được.
- `Q3A_SYNTAX_OK` chỉ biểu thị parse thành công, không biểu thị elaboration hoặc proof thành công.

### 5.3 Parse toàn bộ source trong project

```powershell
& $q3a --parse-project .\prototype\supported-parse.q3a
```

Mỗi source được parse theo thứ tự trong manifest. Nếu một source lỗi, lệnh trả lỗi và dừng.

#### Truy vết macro

Dùng tệp thực thi từ [gói Windows hiện tại](dist/q3aformal-phase1-windows-x64-native-dialog-candidate.zip). Chạy lệnh với manifest phiên bản 2. Đầu ra JSON chứa các token đã tiền xử lý và nguồn gốc macro theo thứ tự tệp trong manifest.

```powershell
& $q3a --preprocess-project .\prototype\pdr-pipeline.q3a > preprocess.json
```

Trường `source_set_sha256` khớp với lần chạy proof dùng cùng thiết lập manifest. Trong mỗi bản ghi mở rộng, `invocation` là nơi gọi macro ngoài cùng. `steps` liệt kê các định nghĩa đã dùng theo thứ tự xử lý. Khoảng token bắt đầu tại `output_begin` và kết thúc ngay trước `output_end`. Macro dùng làm tên tệp include hoặc sinh kết quả rỗng có hai chỉ số bằng nhau.

### 5.4 Elaborate project

```powershell
& $q3a --elaborate-project .\prototype\parameterized-hierarchy.q3a
```

Output báo top module, parameter/localparam đã resolve, port, signal, static generate scope và hierarchy instance/connection trong phạm vi hỗ trợ. Elaboration hiện là một phần, chưa bao gồm toàn bộ semantics của SystemVerilog.

### 5.5 Xuất T-IR một phần

```powershell
& $q3a --lower-project .\prototype\counter4.q3a
```

Lệnh in JSON T-IR ra standard output. Schema hiện tại là `Q3A-TIR-0.4`. T-IR lưu guard khởi tạo `$past` riêng cho antecedent và consequent, tính theo vị trí lấy mẫu trong từng sequence; implication có `$past` ở term trễ sẽ được kiểm tra khi lịch sử hợp lệ tại term đó. Bundle T-IR `0.3` vẫn được mở theo trường guard tổng hợp cũ. T-IR có thể chứa biểu thức tổ hợp, next-state equation, SVA sequence automata và `$past` history equations tùy subset của input. Hierarchy hiện hỗ trợ property inline/named trong child đến ba cấp đã có regression; output scalar của child, kể cả state output, có thể nối vào bit-select hằng của packed bus nếu toàn bộ bit được phủ chính xác. Mỗi state lane vẫn là state riêng; property được namespace theo instance và clock/port được ánh xạ qua wrapper.

Có thể chuyển output sang file bằng shell redirection:

```powershell
& $q3a --lower-project .\prototype\counter4.q3a > .\counter4.tir.json
```

Hiện không có tùy chọn `--output`. `--lower-project` không chạy SAT solver và không đưa ra kết quả PROVEN/FAIL cho property RTL.

### 5.6 Sinh transition relation CNF theo số bước hữu hạn

```powershell
& $q3a --transition-cnf .\prototype\lower-multi-process.q3a --frames 1 > .\transition.cnf
```

`N` là chỉ số frame cuối cùng: lệnh tạo frame `0` đến `N` và `N` transition giữa chúng. Mỗi frame có biến riêng cho mọi bit tín hiệu. T-IR combinational equations được áp dụng trong từng frame; mỗi next-state equation nối trạng thái frame `t` sang frame `t+1`. Trạng thái RTL ban đầu không bị ràng buộc. Các state validity do `$past` sinh ra được khởi tạo bằng 0 theo model contract.

Output gồm comment `c q3a_transition_cnf`, các dòng `c q3a_signal` ánh xạ frame/tín hiệu/bit sang biến SAT, rồi header và clauses DIMACS. Chạy SAT solver nội bộ trên file đó bằng `--sat-dimacs`. Ví dụ kiểm tra một chuyển trạng thái cụ thể bằng assumptions cần dùng số biến từ các dòng ánh xạ:

```powershell
& $q3a --sat-dimacs .\transition.cnf --assume <signed-literal> --assume <signed-literal>
```

Lệnh này chỉ sinh transition relation. Nó chưa thêm query từ `assert property`, assume môi trường, hoặc cover. Vì vậy SAT/UNSAT của file relation tự nó không phải kết quả formal verification cho property RTL. Hiện giới hạn transition depth là 10,000; subset bit-blast có width tối đa 64 bit, một clock domain, và chỉ các expression đã được implement.

### 5.7 Chạy bounded check cho assertion

```powershell
& $q3a --bmc .\prototype\bmc-scalar.q3a --property p_can_fail --frames 3
```

Thêm `--vcd <file.vcd>` để lưu trace của counterexample hoặc cover witness đã replay thành công:

```powershell
& $q3a --bmc .\prototype\bmc-state-failure.q3a `
    --property p_q_tracks_a --frames 1 `
    --vcd .\q3aformal-witness.vcd --html .\q3aformal-witness.html
```

Lệnh tạo transition relation từ frame `0` đến `N`, áp các assumption được hỗ trợ, rồi tìm một violation của assertion trong bound. Query hỗ trợ assertion scalar, standalone linear sequence assertion, và implication tuyến tính `|->`/`|=>`; mỗi term có predicate một bit, delay hằng, finite range ##[m:n], và positive bounded consecutive repetition. Biểu thức được hỗ trợ gồm các phép toán được liệt kê ở mục 1 và static bit/part select trên packed vector có range xác định. Với standalone sequence assertion, mỗi complete property-start phải có ít nhất một match path; start không đủ maximum horizon được báo incomplete. Mỗi match end của antecedent tạo obligation riêng. Một obligation chỉ được kiểm tra khi toàn bộ horizon tối đa của consequent nằm trong bound; các obligation vượt quá frame cuối bị hoãn khỏi query hữu hạn. Scalar và linear sequence assumptions được áp cho các start có complete match trong bound; implication assumptions được áp cho từng antecedent match có consequent horizon hoàn chỉnh. `$past` chỉ hoạt động khi history guard đã valid.

Các trạng thái:

- `BOUNDED_FAIL`: tìm được counterexample trong giới hạn đã yêu cầu. Trước khi status này được in, Q3AFormal decode model SAT thành các giá trị tín hiệu theo frame rồi replay độc lập các phương trình T-IR, assumptions và assertion đang xét. Replay phải hợp lệ; nếu không, lệnh báo lỗi thay vì công bố counterexample. Output có candidate frame và các dòng `Q3A_BMC_TRACE_SIGNAL` cho từng tín hiệu/frame; đây là trace dạng text.
- `BOUNDED_PASS`: không tìm thấy violation trong bound. Đây không phải chứng minh unbounded.
- `INCONSISTENT_MODEL_OR_ASSUMPTIONS`: transition relation và assumptions không có model thỏa.
- `UNKNOWN`: SAT solver chạm giới hạn hoặc không kết luận. Với cover query không tìm thấy witness trong bound, status cũng là `UNKNOWN`; xem trường `Q3A_BMC_COVER_RESULT` để biết reason.
- `Q3A_BMC_WAVEFORM WRITTEN`: VCD đã lưu sau replay thành công; nếu query không tạo witness thì output là `NOT_WRITTEN` và không tạo file.

VCD ánh xạ mẫu số `N` sang timestamp `N` với timescale `1ns`. File giữ bit clock theo witness và biểu diễn cạnh lấy mẫu bằng tín hiệu kiểu `event` trong scope riêng. Timestamp thể hiện bước lấy mẫu rời rạc. Trình xem HTML mở tại mẫu witness và có nút `Witness frame` để quay lại mẫu đó.

Thêm `--html <file.html>` để tạo waveform viewer dạng HTML độc lập từ cùng witness đã replay hợp lệ. Mở file HTML bằng trình duyệt để xem waveform tín hiệu một bit và bus vector, lọc tín hiệu theo tên, điều chỉnh frame cursor bằng thanh trượt hoặc bấm trực tiếp trên waveform; giá trị hiện tại được hiển thị bên cạnh mỗi tín hiệu. Viewer dùng JavaScript/SVG tích hợp trong file, không tải thư viện hay tài nguyên mạng. Clock vẫn được thể hiện ngầm qua chỉ số frame. Nếu query không tạo witness đã xác thực, cả VCD và HTML đều không được tạo. Dùng tùy chọn này cho debug ở mức frame; đây chưa phải giao diện xem FSDB, timing gate-level hoặc waveform của simulator.

Cover scalar property, linear finite sequence, và linear implication goal có thể chạy bằng cùng lệnh `--bmc`:

```powershell
& $q3a --bmc .\prototype\bmc-scalar-cover.q3a --property property_check_1 --frames 0
& $q3a --bmc .\prototype\bmc-cover-implication.q3a --property c_nonoverlapped --frames 1
```

- `COVERED` kèm `Q3A_BMC_COVER_RESULT WITNESS_FOUND`: tìm thấy witness không vacuous và replay độc lập xác nhận equations, assumptions, cùng cover goal.
- `UNKNOWN` kèm `Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND`: không tìm thấy witness trong giới hạn tìm kiếm. Đây không phải `UNREACHABLE`.

Linear implication cover yêu cầu có antecedent match và consequent match hoàn chỉnh trong bound; vacuous success không tính là reachability witness. Non-linear sequence forms và các dạng temporal ngoài automaton tuyến tính được hỗ trợ sẽ bị từ chối. Sequence expansion bị giới hạn ở 4,096 đường và 1,000,000 lần đánh giá predicate/frame. Output `Q3A_BMC_BOUNDARY_OBLIGATIONS` cho biết các assertion obligation bị bỏ qua vì consequent chưa đủ horizon trong bound. `BOUNDED_PASS` chỉ áp dụng cho obligation đầy đủ trong bound; không xem nó là `PROVEN`.

### 5.8 Giải file SAT theo DIMACS CNF

Tạo ví dụ file `example.cnf`:

```powershell
@'
c (x1 OR x2) AND (NOT x1 OR x2)
p cnf 2 2
1 2 0
-1 2 0
'@ | Set-Content -Encoding Ascii .\example.cnf
```

Chạy solver:

```powershell
& $q3a --sat-dimacs .\example.cnf
```

Output có dạng:

```text
Q3A_SAT_STATUS SAT
Q3A_SAT_STATS variables=<count> clauses=<count> assumptions=<count> decisions=<count> propagations=<count> conflicts=<count> learned=<count> backjumps=<count> nonchrono_backjumps=<count>
Q3A_SAT_MODEL v <signed literals> 0
```

Các giá trị trong dòng thống kê thay đổi theo input. `clauses` đếm clause được solver giữ sau chuẩn hóa; tautology bị loại bỏ.

`SAT`/`UNSAT` chỉ là kết quả cho CNF file đã nhập. Đây không phải kết quả formal verification cho RTL.

### 5.9 Tạo và kiểm tra CNF proof artifact (thử nghiệm riêng)

Build tiện ích tách biệt:

```powershell
.\prototype\checker\build.ps1
```

Tạo DRAT artifact cho một file DIMACS CNF không thỏa được:

```powershell
$modelHash = '<64 hexadecimal digits for the exact model identity>'
& .\prototype\bin\q3aformal-proofcheck.exe `
    --create-drat .\obligation.cnf .\obligation.q3adrat `
    --model-sha256 $modelHash --query-kind induction-base
```

Kiểm tra lại artifact với cùng CNF và metadata mong đợi:

```powershell
& .\prototype\bin\q3aformal-proofcheck.exe `
    --check-drat .\obligation.cnf .\obligation.q3adrat `
    --model-sha256 $modelHash --query-kind induction-base
```

Proof search DPLL giản lược chỉ xử lý CNF độc lập; `--query-kind` và `--model-sha256` do caller cung cấp, còn query hash được tính từ đúng bytes của file CNF. Lệnh chưa xác nhận CNF được sinh từ model hoặc từ induction obligation đã chỉ định. Vì vậy kết quả `Q3A_PROOF_CHECK ACCEPTED` chỉ có nghĩa là DRAT chứng minh đúng CNF cụ thể không thỏa được và metadata trùng giá trị caller yêu cầu; không phải `PROVEN` cho RTL. Xem [giới hạn và schema artifact](prototype/checker/README.md).

### 5.10 Chứng minh scalar, sequence và implication bằng k-induction

Lệnh này tự tạo riêng obligation base và induction step từ project RTL đã lower thành T-IR:

```powershell
New-Item -ItemType Directory -Force .\evidence\trial | Out-Null
& $q3a --prove-inductive .\prototype\known-pass-combinational.q3a `
    --property p_y_implies_a --output-prefix .\evidence\trial\p_y_implies_a
```

Với SVA implication `|->` cùng sample, có thể chạy vector kiểm chứng sau:

```powershell
& $q3a --prove-inductive .\prototype\sva-induction-overlapped.q3a `
    --property p_y_implies_a --output-prefix .\evidence\trial\sva_y_implies_a
```

Induction nhận predicate scalar hoặc chuỗi gồm các predicate một bit nối bằng `##0`. Với `|->`, cả hai vế được lấy ở cùng sample. Chuỗi `(a ##0 b) |-> (c ##0 d)` được mã hóa thành `(!a || !b || c) && (!a || !b || d)`.

Assertion `|=>` được hỗ trợ khi hai vế đều là chuỗi cùng sample, không có delay/repetition khác `##0`, và property không cần guarded `$past`. Consequent được lấy ở sample tiếp theo: `(a ##0 b) |=> (c ##0 d)` tạo các mệnh đề `(!a[t] || !b[t] || c[t+1]) && (!a[t] || !b[t] || d[t+1])`. Có thể chạy vector:

```powershell
& $q3a --prove-inductive .\prototype\sva-induction-nonoverlapped.q3a `
    --property p_pair_implies_next_q --output-prefix .\evidence\trial\sva_pair_next_q
```

Các assumption trong induction nhận scalar và chuỗi tuyến tính một bit có fixed delay, positive bounded repetition, `|->`, hoặc `|=>`. Sequence-only assumptions cần ít nhất một match path ở mỗi start có toàn bộ horizon trong proof window. Với implication assumptions, mỗi antecedent match path tạo một consequent obligation; `|=>` bắt đầu consequent ở sample kế tiếp endpoint. Assumption start ở phần đuôi không đủ maximum horizon được bỏ qua giống nhau trong encoder và independent replay. Delayed assumptions có guarded `$past` bị từ chối; implication assumption `|=>` có guarded `$past` cũng bị từ chối vì history-valid guard hiện được gắn với property start, không phải sample dịch của operand.

Không truyền `--k` thì dùng `k=1`. Có thể chọn depth lớn hơn, ví dụ:

```powershell
& $q3a --prove-inductive .\prototype\known-pass-combinational.q3a `
    --property p_y_implies_a --k 2 `
    --output-prefix .\evidence\trial\p_y_implies_a_k2
```

Với depth `k`, base obligation xét property-start frame `0..k-1`; step giả định property tại các start frame `0..k-1` rồi kiểm tra start frame `k`. Với `|->`, base/step dùng lần lượt `k`/`k+1` sample frame. Với `|=>`, mỗi start cần successor: base dùng sample frame `0..k`, step dùng `0..k+1`; cả `|=>` và các sequence trễ đều phải thỏa `k + target_horizon <= 10000`. Assumptions được áp dụng tại các complete property-start trong proof window; temporal start có full horizon vượt ngoài trace không tạo ràng buộc. Base áp dụng trạng thái khởi tạo của history-valid guard; step để trạng thái frame 0 tự do, kể cả history-valid, như yêu cầu của phép quy nạp. SAT assignment được replay độc lập với phương trình T-IR, assumption và điều kiện base/step trước khi lưu witness. `Q3A_INDUCTION_BASE_FRAMES` và `Q3A_INDUCTION_STEP_FRAMES` là property-start frame ranges. Checker query kind là `induction-base`/`induction-step` khi `k=1`, và `induction-k<k>-base`/`induction-k<k>-step` khi `k>1`.

Kết quả được lưu thành `.base.cnf`, `.step.cnf` và, nếu obligation tương ứng UNSAT, `.base.q3adrat`, `.step.q3adrat`. Nếu obligation SAT, lệnh lưu `.base.witness.txt` hoặc `.step.witness.txt` sau khi replay thành công. Base SAT được báo `Q3A_INDUCTION_STATUS FAIL` và ghi frame lỗi vì đó là trace reachable từ initial state. Step SAT được báo `NOT_<k>_INDUCTIVE`; witness có thể không reachable và không đủ để kết luận thiết kế FAIL. Nếu replay từ chối SAT model, kết quả là `UNKNOWN`. Lệnh không ghi đè file có sẵn. `Q3A_INDUCTION_STATUS PROVEN` chỉ xuất hiện nếu cả base và step đều UNSAT và artifact của cả hai được checker kiểm tra độc lập; output ghi rõ scope `GENERATED_TIR_MODEL`. CNF query hash dùng đúng bytes được lưu; model hash là SHA-256 của serialized T-IR.

Subset hiện tại nhận scalar assertion hoặc chuỗi một-bit cùng sample gồm các term nối bằng `##0`; với property không implication, sequence phải match ở mọi start frame. Standalone scalar assertion sequence còn hỗ trợ fixed delay, finite bounded delay range ##[m:n], và positive bounded repetition (`[*m:n]`, với `m > 0`) nếu automaton là một đường tuyến tính, số tổ hợp repetition không quá 4096, và tổng horizon thỏa `k + horizon <= 10000`. Ví dụ `a[*2] ##2 b[*2]` yêu cầu `a` đúng ở hai sample liên tiếp rồi `b` đúng ở hai sample bắt đầu sau hai chu kỳ. Với bounded repetition, sequence thành công nếu ít nhất một lựa chọn độ dài match; encoder biểu diễn OR giữa các match path và replay kiểm tra độc lập. Delayed scalar assertions không được dùng guarded `$past`. Assertion implication `|->` và `|=>` còn hỗ trợ antecedent/consequent là chuỗi tuyến tính có fixed delay, finite bounded delay range ##[m:n], và positive bounded repetition. Mỗi antecedent match path tạo một obligation riêng cho consequent; với `|=>`, consequent bắt đầu ở sample ngay sau endpoint của antecedent, còn `|->` bắt đầu tại endpoint. Tổng horizon gồm horizon lớn nhất của antecedent, độ dịch implication và horizon lớn nhất của consequent; tổng này cộng `k` không vượt 10000 transition. Ví dụ `(a ##1 b) |-> (c ##2 d)` so khớp `a,b` trước, rồi yêu cầu một match của `c,d` bắt đầu tại endpoint `b`. Nếu operand implication có temporal offset khác 0, guarded `$past` bị từ chối; các implication cùng sample `|->` vẫn giữ guard ở property start. Finite bounded delay range ##[m:n] được hỗ trợ bằng existential endpoint matching; unbounded delay range bị từ chối. Assumption cũng nhận fixed-delay hoặc finite bounded-delay-range sequence và implication với positive bounded repetition. Sequence assumptions cần match ít nhất một path ở mỗi complete start; implication assumptions yêu cầu consequent cho từng antecedent match path. Chỉ các start có toàn bộ maximum horizon trong proof window mới được áp dụng, và các start ở phần đuôi không đủ horizon bị bỏ qua. Delayed assumptions có guarded `$past` bị từ chối. Trạng thái RTL ban đầu không ràng buộc, theo Phase 0 contract. `NOT_<k>_INDUCTIVE` nghĩa là base không tìm thấy lỗi trong prefix và step có model SAT; step witness có thể unreachable. `UNKNOWN` nghĩa là proof search chạm giới hạn hoặc SAT witness không replay được. `PROVEN` là kết quả cho property trong T-IR đã tạo, không xác nhận correctness của source-to-T-IR translation.

Có thể tùy chọn cache các proof DRAT đã kiểm tra cho base/step để tránh chạy lại SAT solver khi toàn bộ identity khớp:

```powershell
& $q3a --prove-inductive .\prototype\known-pass-combinational.q3a `
    --property p_y_implies_a `
    --output-prefix .\evidence\trial\p_y_implies_a_cached `
    --cache-dir .\evidence\proof-cache
```

Lần đầu sẽ báo `STORED`; lần sau có thể báo `HIT`. Trước khi báo HIT, Q3AFormal tạo lại đúng model/CNF và dùng DRAT checker hiện tại kiểm tra proof đã lưu. Thay đổi source/model, profile, query, build, checker, property, depth hoặc cấu hình solver sẽ tạo cache miss. Cache không lưu witness SAT, kết quả `UNKNOWN`, BMC, hoặc trạng thái tìm kiếm. Nếu cache không dùng được, solver vẫn chạy mới; cache không làm thay đổi cách phân loại kết quả. Xem [chi tiết proof cache](prototype/source/cache/README.md).

### 5.11 Lưu run bundle có định danh và hash

Lệnh sản phẩm `prove` tự lưu phản ví dụ assertion đã qua phát lại độc lập vào thư mục con mới của `q3aformal-results` trong thư mục làm việc. Trường JSON `bundle_dir` chứa đường dẫn tuyệt đối để mở lại bằng `--verify-bundle`. Cơ chế này áp dụng cho BMC, phản ví dụ khả đạt từ bước cơ sở của k-induction, và phản ví dụ PDR. Dùng `--bundle-dir` để chọn vị trí khác. Nếu không thể ghi bundle bắt buộc, `prove` trả `ENGINE_ERROR` với mã thoát `3`. Các lệnh Phase 0 `--bmc` và `--prove-inductive` tiếp tục yêu cầu tùy chọn rõ ràng để lưu bundle.

Thêm `--bundle-dir` để lưu project snapshot, RTL, T-IR, query CNF, kết quả property, checker/build identity và SHA-256 vào một thư mục bundle mới:

```powershell
& $q3a --bmc .\prototype\bmc-state-failure.q3a `
    --property p_q_tracks_a --frames 1 `
    --bundle-dir .\evidence\trial\bmc-run

& $q3a --prove-inductive .\prototype\known-pass-combinational.q3a `
    --property p_y_implies_a `
    --output-prefix .\prototype\bin\trial-induction `
    --bundle-dir .\evidence\trial\induction-run
```

Bundle output path phải chưa tồn tại; Q3AFormal không ghi đè evidence cũ. `manifest.json` liệt kê schema, status, profile, source/model/query/build/checker identity, assumption names, reset/initial-state policy, giới hạn tài nguyên, và role/size/hash của từng artifact. Giá trị limit bằng `0` có nghĩa là không giới hạn. `manifest.sha256` là hash của chính manifest. Các artifact nằm dưới những thư mục `source-snapshot/`, `model/`, `queries/`, `properties/` và, nếu yêu cầu `--vcd` cùng `--bundle-dir`, `trace/`. BMC trace JSON chỉ được lưu sau khi replay độc lập thành công; induction bundle lưu hai CNF, DRAT đã kiểm tra, và witness đã replay nếu có.

Khi dùng `--bundle-dir`, tool công bố kết quả truy vấn sau khi ghi xong bundle. Nếu không thể ghi bundle, tool trả mã thoát `1` và báo lỗi xuất kết quả.

### Bộ nhớ khi chạy formal

Lệnh `--bmc` chỉ tuần tự hóa mô hình và ghi truy vấn khi yêu cầu `--bundle-dir`. Bundle ghi truy vấn và trace JSON trực tiếp vào thư mục tạm, sao chép waveform theo từng khối 64 KiB rồi công bố thư mục hoàn chỉnh. Kiểm tra xem điều kiện kích hoạt của property có thể xảy ra dùng chung truy vấn gốc và một clause tạm. Phép quy nạp chuyển quyền sở hữu bản ghi chứng minh sang bước kiểm tra để tránh tạo thêm một bản sao.

Trên Windows, `--bmc` và `--prove-inductive` đọc RAM còn khả dụng khi bắt đầu. Ngân sách mặc định cho bộ nhớ riêng của tiến trình bằng mức đang dùng cộng một nửa lượng RAM khả dụng lúc đó. Tool cũng kiểm tra định kỳ lượng RAM khả dụng còn lại, với mức dự phòng bằng một phần tư lượng ban đầu và tối đa 512 MiB. MiB là mebibyte, tương đương 1.048.576 byte.

Bộ giải lưu các mệnh đề gốc trong một vùng bộ nhớ liền mạch để giảm chi phí cấp phát cho từng mệnh đề. Trước khi mở rộng vùng này, tool kiểm tra ngân sách cho vùng mới trong lúc vùng cũ vẫn còn tồn tại.

Ví dụ dưới đây đặt trần 2.048 MiB, yêu cầu chừa 1.536 MiB RAM khả dụng cho Windows và các ứng dụng, và dùng thư mục tạm trên ổ đĩa bạn chọn. Tạo thư mục tạm một lần trước khi chạy.

```powershell
$env:Q3A_MEMORY_LIMIT_MIB = '2048'
$env:Q3A_MEMORY_RESERVE_MIB = '1536'
$env:Q3A_SCRATCH_DIR = (New-Item -ItemType Directory -Force .\q3a-scratch).FullName
# Chạy lệnh --bmc hoặc --prove-inductive như bình thường.
Remove-Item Env:Q3A_MEMORY_LIMIT_MIB, Env:Q3A_MEMORY_RESERVE_MIB, Env:Q3A_SCRATCH_DIR
```

Khi chạm giới hạn bộ nhớ, lệnh sản phẩm `prove` trả `RESOURCE_LIMIT`, mã thoát `1` và trường JSON `resource_limit: memory`. Nếu chạm giới hạn trong engine, lệnh Phase 0 `--bmc` hoặc `--prove-inductive` vẫn trả `UNKNOWN`, mã thoát `3` và chẩn đoán `Q3A_RESOURCE_LIMIT MEMORY`. Các điểm kiểm tra nằm quanh giai đoạn xây mô hình, mã hóa và giải truy vấn. Tiến trình có thể tăng bộ nhớ giữa hai lần kiểm tra. Trần này đo bộ nhớ riêng được cam kết của tiến trình. Benchmark Phase 0 ghi working set đỉnh, tức số trang của tiến trình đang nằm trong RAM.

Khi mở lại bundle, trình xác minh băm tệp theo khối 64 KiB. Các tệp phụ như waveform và bản sao nguồn chỉ cần kiểm tra kích thước và mã băm. Dữ liệu dùng để replay hoặc kiểm chứng được nạp lại theo từng phép kiểm tra. Mô hình, cơ sở mệnh đề SAT và trạng thái tìm kiếm vẫn dùng RAM.

Lệnh `q3aformal-proofcheck --check-drat` đọc chứng thư từ đĩa theo từng dòng. Luồng quy nạp ghi cả hai truy vấn CNF và bản ghi chứng minh vào đĩa tạm. Mặc định vị trí tạm nằm cạnh đường dẫn `--output-prefix`. Đặt `Q3A_SCRATCH_DIR` để chọn một thư mục đã tồn tại trên ổ khác. Thư mục đầu ra và thư mục tạm cần đủ dung lượng. Q3AFormal dọn tệp tạm khi thoát theo luồng bình thường, kể cả khi chạm giới hạn RAM. Checker đọc trực tiếp từ tệp tạm và chứng thư chỉ được công bố sau khi checker chấp nhận. Cache cũng đọc truy vấn và chứng thư theo luồng từ đĩa.

`Q3A_MEMORY_LIMIT_MIB` và `Q3A_MEMORY_RESERVE_MIB` cũng áp dụng khi kiểm tra chứng thư, kiểm tra lại cache và mở bundle. Checker độc lập trả `RESOURCE_LIMIT` nếu chạm ngân sách. Lệnh xác minh bundle giữ mã thoát `3` cho trường hợp không thể kết luận do giới hạn tài nguyên. Cache giữ mục đang có để lần chạy với ngân sách lớn hơn có thể kiểm tra lại.

Kết quả mâu thuẫn giữa assumptions được lưu cùng feasibility CNF và status `INCONSISTENT_MODEL_OR_ASSUMPTIONS`, không được coi là pass/fail chức năng. Dùng `--verify-bundle` trong mục 5.12 để kiểm tra lại một bundle đã lưu. Proof cache hỗ trợ các truy vấn k-induction được chấp nhận; bundle vẫn lưu source/model/query/evidence đầy đủ. Xem [tài liệu bundle](prototype/source/bundle/README.md).

Khóa proof cache bao gồm mã băm của chính tệp project manifest. Đổi nội dung manifest sẽ tạo khóa mới dù mô hình và truy vấn vẫn giống nhau. Hai bản sao manifest giống nhau từng byte có thể dùng lại proof khi các định danh còn lại trùng khớp.

### 5.12 Mở bundle và kiểm tra lại evidence

`--verify-bundle` chỉ đọc thư mục bundle. Lệnh xác minh hash manifest, snapshot source/RTL, T-IR, query CNF, và toàn bộ artifact được manifest liệt kê. Nếu có DRAT proof và checker ID/schema/source fingerprint tương thích, Q3AFormal kiểm tra lại từng cặp proof/CNF theo đúng model/query hash:

```powershell
& $q3a --verify-bundle .\evidence\known-pass\run-bundle-2026-11-16-v2
& $q3a --verify-bundle .\evidence\known-fail\run-bundle-2026-11-16-v2
```

Kết quả known-pass có thể báo `Q3A_BUNDLE_STATUS REVALIDATED` vì có base/step DRAT artifact tương thích. Với bundle BMC có witness, verifier dựng lại subset T-IR được hỗ trợ từ JSON, rồi replay độc lập trace qua phương trình, assumptions và property. Output gồm `Q3A_BUNDLE_TRACE_REPLAY VALIDATED` và scope `REPLAYED_BMC_WITNESS_FOR_SERIALIZED_TIR`. Với assertion `BOUNDED_PASS` không có witness và cover miss `UNKNOWN`, verifier có thể tái tạo CNF từ T-IR đã lưu, yêu cầu CNF khớp từng byte, xác nhận model/assumptions khả thi và chạy lại truy vấn UNSAT khi fingerprint SAT bit-blaster tương thích. Cover miss vẫn là `NOT_FOUND_WITHIN_BOUND`, không phải `UNREACHABLE`. Những kết quả này chỉ xác nhận truy vấn trên T-IR đã lưu; không xác nhận RTL được dịch đúng sang T-IR. Nếu không có bằng chứng revalidation tương thích, bundle giữ trạng thái `HISTORIC`. Hash, CNF tái tạo hoặc DRAT không khớp sẽ gây lỗi và lệnh trả exit code khác 0. Proof cache của lệnh k-induction không cache bundle.

`Q3A_BUNDLE_VCD VERIFIED` xác nhận VCD trong bundle BMC khớp với danh sách tín hiệu, chỉ số mẫu và giá trị từ witness đã phát lại. Khi mô hình được dựng lại từ RTL, công cụ cũng đối chiếu khai báo dải bit với RTL. VCD lịch sử có thể biểu diễn xung lấy mẫu bằng các mốc thời gian và lược bỏ tín hiệu clock. VCD nhập riêng bằng `trace import-vcd` chỉ dùng để xem waveform.

Dùng chế độ yêu cầu nguồn để đối chiếu bằng chứng với trình biên dịch Q3AFORMAL hiện tại.

```powershell
& $q3a --verify-bundle .\run-bundle --require-source-model
```

Lệnh biên dịch lại các tệp RTL/SVA đã lưu trong bundle, kể cả khi fingerprint của trình biên dịch cũ khác bản đang chạy. Mã thoát 0 yêu cầu mô hình tái tạo khớp và bằng chứng được xác minh lại. Kết quả thành công có cả `Q3A_BUNDLE_SOURCE_MODEL VERIFIED` và `Q3A_BUNDLE_STATUS REVALIDATED`. Mô hình khác, bằng chứng chỉ còn trạng thái lịch sử hoặc tệp record của lượt chạy bị gián đoạn trả mã 1. Chế độ này cũng tái tạo truy vấn Boolean dạng Conjunctive Normal Form (CNF) khi fingerprint của bộ mã hóa SAT cũ khác bản hiện tại. Hash của CNF tái tạo phải khớp bản lưu trước khi kiểm tra proof, phát lại witness hoặc chạy lại truy vấn có giới hạn. Trình kiểm tra DRAT hiện tại có thể kiểm tra lại proof từ bản có fingerprint khác nếu định dạng và ID checker của artefact còn được hỗ trợ. Kiểm tra này xác nhận khả năng tái tạo bằng trình biên dịch hiện tại. [Phạm vi xác minh bundle](prototype/source/bundle/README.md)

### Phạm vi kiểm tra giả định

Kết quả của từng thuộc tính có thể chứa `environment_feasibility` sau khi công cụ thử kiểm tra tính khả thi. Trạng thái `SAT` xác nhận có tiền tố hợp lệ đến mẫu `bound`, còn `UNSAT` xác nhận không có tiền tố hợp lệ trong truy vấn đó. `INITIAL_SAMPLE` áp dụng cho mẫu 0. `FINITE_PREFIX` áp dụng cho tiền tố nhiều mẫu. `UNKNOWN` nghĩa là truy vấn chưa quyết định được. Mốc `bound` mô tả phạm vi truy vấn và có thể nằm sau mẫu mâu thuẫn đầu tiên.

Với PDR, trường này ghi lần kiểm tra tiền tố đã hoàn thành, bao gồm lần kiểm tra khi phát lại witness nếu có. Nếu ngân sách dừng lần kiểm tra kế tiếp, kết quả có thể vẫn ghi tiền tố ngắn hơn đã xác nhận. Trạng thái proof của thuộc tính nằm ở trường `status` riêng.

Để yêu cầu PDR kiểm tra tính khả thi sâu hơn, thêm `--feasibility-frames N` vào tùy chọn của engine. `N` nằm trong khoảng 0 đến 128 và đếm số chuyển trạng thái kể từ mẫu 0. Ví dụ, `--max-depth 1 --feasibility-frames 3` giữ giới hạn tìm kiếm PDR ở độ sâu 1 và kiểm tra giả định đến hết mẫu 3. Truy vấn này dùng chung ngân sách `--max-queries`, thời gian và bộ nhớ của lượt chạy. Job PDR trong kế hoạch batch phiên bản 2 dùng `feasibility_frames N`.

Khi BMC, k-induction hoặc PDR xác nhận giả định mâu thuẫn, `--bundle-dir` lưu truy vấn khả thi cùng mã nguồn và mô hình. Kiểm tra lại bằng `--verify-bundle <dir> --require-source-model`. Bundle này ghi kết quả `INCONSISTENT_MODEL_OR_ASSUMPTIONS` và chỉ chứa bằng chứng về tiền tố đã kiểm tra. Trình xác minh dựng lại và chạy truy vấn đó một lần nữa.

## 7. Tùy chọn của `--sat-dimacs`

| Tùy chọn | Ý nghĩa |
|---|---|
| `--decision-limit N` | Giới hạn số nhánh quyết định. `0` nghĩa là không giới hạn. |
| `--propagation-limit N` | Giới hạn số phép propagation. `0` nghĩa là không giới hạn. |
| `--assume LIT` | Thêm một literal tạm thời làm assumption cho lần giải hiện tại. Dùng nhiều lần nếu cần. Literal dương yêu cầu biến đúng; literal âm yêu cầu biến sai; `0` không hợp lệ. |

Ví dụ:

```powershell
& $q3a --sat-dimacs .\example.cnf --decision-limit 100000 --propagation-limit 2000000
& $q3a --sat-dimacs .\example.cnf --assume 1 --assume -2
```

Assumptions chỉ có hiệu lực trong một lần gọi. Solver chưa giữ learned clause hoặc trạng thái tìm kiếm giữa các lần gọi.

Định dạng DIMACS được chấp nhận:

- Header `p cnf <variable_count> <clause_count>`.
- Literal là số nguyên có dấu, kết thúc mỗi clause bằng `0`.
- Clause có thể trải qua nhiều dòng; dòng comment bắt đầu bằng `c`.
- Số biến/literal và số clause phải khớp header; literal phải nằm trong phạm vi khai báo.

## 8. Output và exit code

Các lệnh ghi kết quả thông thường ra standard output và diagnostic ra standard error. Dùng `q3aformal-sourcecheck.exe --help` để tra các lệnh sản phẩm và `q3aformal-sourcecheck.exe --version` để lấy JSON gồm mã build, bộ biên dịch, cờ build và định danh bộ kiểm tra DRAT.

| Exit code | Ý nghĩa |
|---:|---|
| `0` | Lệnh hoàn tất; với DIMACS, trạng thái là `SAT` hoặc `UNSAT`; BMC trả một trạng thái bounded. |
| `1` | Lỗi đọc input, cú pháp, elaboration, lowering hoặc lỗi xử lý. |
| `2` | Cú pháp command line hoặc option không hợp lệ. |
| `3` | SAT solver dừng với `UNKNOWN` do chạm giới hạn tài nguyên. |

## 9. Giới hạn cần biết

- Q3AFormal chứng minh được thuộc tính RTL xuyên suốt từ mã nguồn đến chứng chỉ DRAT trong phạm vi một clock và mô hình hai giá trị đã công bố. [Phạm vi Phase 1](specs/003-phase1-block-mvp/plan.md#supported-phase-1-language-profile).
- Parser, elaborator và lowerer chỉ hỗ trợ các subset được mô tả trong [conformance matrix](prototype/corpus/conformance-matrix.csv) và [lowering guide](prototype/source/lowering/README.md). `logic`/`bit` declarations không khởi tạo trong active scoped static generate blocks có hỗ trợ tập trung ở SM-036; generated local parameters, declaration initializers, declarations ngoài scoped generate blocks, dynamic/indexed child output selects và expression-valued output actuals chưa được hỗ trợ. Constant direction-matched child output part-selects có exact width và complete parent-bus coverage được hỗ trợ: SM-037 kiểm tra output tuần tự, SM-038 kiểm tra output tổ hợp qua hierarchy trực tiếp và qua wrapper.
- Transition CNF chỉ bao gồm các phương trình của T-IR đã lower thành công; BMC hỗ trợ scalar properties, standalone linear sequence assertions, linear implication automata và bounded scalar/sequence/implication cover goals. Có thể dùng phép lặp liên tiếp với số lần dương hoặc khoảng dương trên chuỗi nhiều bước thuộc profile, ví dụ `(a ##1 b)[*2:3]`. Từng engine áp dụng giới hạn mở rộng chuỗi riêng. Replay độc lập chỉ bao phủ cùng expression/property subset; đây chưa phải implementation đầy đủ semantics SVA.
- T-IR bit-blaster hỗ trợ expression tối đa 64 bit trong operator subset tại [SAT core README](prototype/source/sat/README.md). Với các toán tử đã triển khai, toán hạng khác độ rộng được mở rộng đến độ rộng kết quả; chỉ sign-extend khi cả hai toán hạng signed, ngược lại zero-extend. Đây là hỗ trợ có giới hạn, chưa phải tuân thủ đầy đủ quy tắc sizing của IEEE 1800.
- Hằng 64 bit không dấu giữ nguyên toàn bộ mẫu bit khi xuất mô hình, giải bài toán và phát lại phản ví dụ. Mô hình JSON ghi giá trị theo dấu của khai báo, nên `64'hffff_ffff_ffff_ffff` được ghi là `18446744073709551615` khi không dấu và `-1` khi có dấu.
- BMC dùng lại một tập giới hạn các mệnh đề SAT đã học từ truy vấn khả thi khi thêm mục tiêu thuộc tính. Bộ giải dựng lại watch và trail cho từng lượt. PDR có thể tự tìm invariant và kiểm tra ba nghĩa vụ DRAT trong phạm vi SVA hữu hạn. Cam kết bao phủ toàn bộ RTL/SVA cần thêm bằng chứng. K-induction lưu proof log từ CDCL và xác nhận bằng DRAT checker độc lập; phạm vi induction hiện có scalar predicates, same-sample sequences, standalone scalar assertion sequence và assertion implication sequence với fixed delay, finite bounded delay range, cùng positive bounded repetition. Assumptions được hỗ trợ với finite bounded delay range tại complete proof-window starts; Khoảng trễ vô hạn nằm ngoài phạm vi hiện tại. DRAT checker kiểm tra các nghĩa vụ CNF được tạo cho mô hình RTL/SVA đã hỗ trợ. VCD chỉ biểu diễn bounded T-IR sample frames; replay hiện có chỉ kiểm tra bounded scalar, linear implication và scalar/sequence/nonvacuous implication-cover subset; full vacuity coverage counters are not represented.
- Không diễn giải `Q3A_SYNTAX_OK`, `Q3A_ELABORATED`, JSON T-IR hợp lệ hoặc `SAT` của file DIMACS riêng lẻ thành bằng chứng thiết kế RTL đúng.

## 10. Tài liệu liên quan

- [Release R17 Preview](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview)
- [README của repo](../README.md)
- [Hướng dẫn build Linux](docs/linux.md)
- [Source manager, manifest và build](prototype/source/source_manager/README.md)
- [Frontend subset](prototype/source/frontend/README.md)
- [Lowering và T-IR](prototype/source/lowering/README.md)
- [SAT core và bit-blaster](prototype/source/sat/README.md)
- [CNF proof artifact prototype](prototype/checker/README.md)
- [Versioned run bundles and reopen/revalidation](prototype/source/bundle/README.md)
- [T019 proof artifact progress](prototype/corpus/results/t019-drat-artifact-progress.md)
- [Phase 0 model contract](docs/phase0/model-contract.md)
