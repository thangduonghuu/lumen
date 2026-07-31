# GOAL: AI Command Suggestion Tool cho Terminal (giống Kiro CLI)

## 1. Tổng quan dự án

Xây dựng một **shell plugin** viết bằng **Rust**, cung cấp gợi ý lệnh (command
suggestion) dựa trên AI, hiển thị dạng **popup/dropdown** ngay bên dưới dòng
lệnh khi người dùng gõ trong terminal. Mục tiêu là một plugin nhẹ, dễ cài,
nhúng được vào shell hiện có của người dùng (không phải một terminal emulator
riêng).

**MVP target shell:** Zsh (mở rộng sang Bash, Fish ở giai đoạn sau).

---

## 2. Tính năng cốt lõi

### 2.1 AI Suggestion Engine
- Gợi ý lệnh dựa trên **ngữ cảnh**: thư mục hiện tại, lịch sử lệnh gần đây,
  output của lệnh trước, git status, loại project (package.json, Cargo.toml,
  requirements.txt, v.v.)
- Hỗ trợ **2 chế độ backend AI**, người dùng cấu hình qua file config:
  - **Cloud API**: OpenAI / Anthropic / Gemini (cần API key + internet)
  - **Local model**: qua Ollama hoặc llama.cpp (chạy offline)
- Có cơ chế **fallback**: nếu cloud lỗi/không có mạng → dùng local (nếu có
  cấu hình) hoặc tắt tính năng AI, chỉ giữ lại gợi ý tĩnh (lịch sử/alias).

### 2.2 UI hiển thị
- **Popup/dropdown** xuất hiện bên dưới con trỏ khi gõ lệnh, dạng list có
  thể điều hướng bằng phím mũi tên (↑/↓), chọn bằng Tab/Enter, đóng bằng Esc.
- Hiển thị không chặn (non-blocking): không được làm gián đoạn việc gõ lệnh
  bình thường, chỉ render khi có đủ debounce time (vd 150–300ms sau khi
  ngừng gõ) để tránh gọi AI liên tục.
- Có chỉ báo trạng thái nhỏ (loading spinner / icon) khi đang chờ AI trả lời.

### 2.3 Nhúng vào Zsh
- Cơ chế nhúng: **ZLE widget** (Zsh Line Editor) — đây là cách chuẩn để can
  thiệp vào dòng lệnh đang gõ (giống cách zsh-autosuggestions,
  zsh-syntax-highlighting hoạt động).
- Cài đặt đơn giản qua: Homebrew / cài script / hoặc plugin manager
  (zinit, oh-my-zsh custom plugin).

---

## 3. Kiến trúc kỹ thuật đề xuất

```
┌─────────────────────────────────────────────┐
│                Zsh (ZLE)                     │
│   - Bắt sự kiện gõ phím (zle-line-pre-redraw)│
│   - Gọi binary Rust qua stdin/stdout hoặc     │
│     unix socket (để giảm latency spawn process)│
└───────────────┬───────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────┐
│         Rust Core Daemon (background)        │
│  - Context collector (cwd, history, git, ...) │
│  - Debounce & cache layer                     │
│  - AI Provider abstraction (trait)            │
│      ├─ CloudProvider (OpenAI/Anthropic/Gemini)│
│      └─ LocalProvider (Ollama/llama.cpp)      │
│  - Render suggestion list → trả về Zsh        │
└─────────────────────────────────────────────┘
```

**Vì sao chạy daemon nền thay vì spawn process mỗi lần gõ phím:**
Gõ phím xảy ra liên tục, nếu spawn process Rust mới mỗi lần sẽ chậm và tốn
tài nguyên. Daemon giữ kết nối AI, cache, và context sẵn sàng, giao tiếp qua
Unix socket cho nhanh.

### Tech stack đề xuất
| Thành phần | Công nghệ |
|---|---|
| Ngôn ngữ chính | Rust |
| Giao tiếp Zsh ↔ Rust | Unix domain socket (crate: `tokio`, `interprocess`) |
| Async runtime | `tokio` |
| HTTP client (gọi API cloud) | `reqwest` |
| Local model | gọi Ollama qua HTTP local (`localhost:11434`) |
| Config | file `~/.config/ai-suggest/config.toml`, parse bằng `serde` + `toml` |
| Terminal rendering phụ trợ (nếu cần vẽ UI phức tạp) | `crossterm` |

---

## 4. Phạm vi MVP (giai đoạn 1)

- [x] Rust daemon chạy nền, giao tiếp qua unix socket
- [x] Zsh widget bắt sự kiện gõ, gửi context (buffer hiện tại + cwd) tới daemon
- [x] Daemon gọi 1 provider AI (chọn cloud HOẶC local qua config) → trả gợi ý
- [x] Hiển thị popup đơn giản dưới dòng lệnh, điều hướng bằng phím mũi tên
- [x] Chọn gợi ý bằng Tab/Enter để chèn vào dòng lệnh
- [x] File config cơ bản: chọn provider, API key, model

### 4.1 Giai đoạn 1a (hiện tại): tắt AI, chỉ dùng gợi ý tĩnh

Lý do tạm tắt: model local (Ollama, kể cả bản nhỏ `qwen3:8b` lẫn
`qwen2.5-coder:14b`) trả lời quá chậm (~10–40s) so với debounce 250ms của
tính năng gõ-tới-đâu-gợi-ý-tới-đó — cảm giác như tính năng bị đứng/không
hoạt động dù thực chất request vẫn chạy ngầm. Quyết định: tạm gác AI lại,
tập trung hoàn thiện phần gợi ý tĩnh (bảng subcommand cứng cho
git/docker/kubectl/npm) cho mượt và đúng trước, AI tính sau.

- [x] `_ai_suggest_schedule` (đường gọi AI tự động khi gõ) không còn được
      gọi từ `_ai_suggest_suggest_now` — chỉ còn bảng tĩnh
- [x] Ctrl-Space (`_ai_suggest_trigger`) không gọi AI nữa; buffer ngoài bảng
      tĩnh chỉ hiện thông báo "không có gợi ý tĩnh cho lệnh này"
- [x] Bỏ gợi ý từ lịch sử lệnh (`_ai_suggest_history_match`) — chỉ còn bảng
      tĩnh làm nguồn gợi ý duy nhất trong giai đoạn này
- [ ] Review/mở rộng bảng tĩnh: thêm tool khác nếu cần (vd `cargo`, `yarn`),
      hoàn thiện các subcommand còn thiếu cho git/docker/kubectl/npm

Code của đường AI (`_ai_suggest_schedule`, `_ai_suggest_fd_handler`,
`_ai_suggest_notify_async`, daemon/client/provider Rust) vẫn giữ nguyên,
KHÔNG xoá — chỉ đơn giản là không có gì gọi tới nữa. Bật lại AI ở giai đoạn
sau chỉ cần gọi lại `_ai_suggest_schedule` trong `_ai_suggest_suggest_now`
(và khôi phục nhánh AI trong `_ai_suggest_trigger`), không cần viết lại từ
đầu.

### 4.2 Giai đoạn 1b (tiếp theo): bật lại AI

- [ ] Chọn model/provider đủ nhanh cho debounce 250ms (model local nhỏ hơn,
      hoặc mặc định dùng cloud (Anthropic) cho đường tự động, local chỉ
      dùng cho Ctrl-Space nơi người dùng chấp nhận chờ)
- [ ] Gọi lại `_ai_suggest_schedule` trong `_ai_suggest_suggest_now`
- [ ] Khôi phục nhánh gọi AI trong `_ai_suggest_trigger` (Ctrl-Space)
- [ ] Đánh giá lại: có cần thêm lại gợi ý từ lịch sử lệnh không, hay để AI
      (đã có context lịch sử gần đây qua `AI_SUGGEST_HISTORY_COUNT`) đảm
      nhiệm luôn phần đó

## 5. Giai đoạn 2 (mở rộng)
- [ ] Hỗ trợ Bash, Fish
- [ ] Cache gợi ý theo context để giảm gọi AI lặp lại
- [ ] Học từ lịch sử lệnh cá nhân (fine-tune ngữ cảnh, không phải train model)
- [ ] Gợi ý sửa lỗi khi lệnh chạy fail (dựa trên exit code + stderr)
- [ ] Cấu hình fallback cloud ↔ local tự động

---

## 6. Câu hỏi mở cần quyết định khi bắt đầu code
1. Unix socket hay stdin/stdout pipe cho giao tiếp Zsh ↔ daemon? (socket
   khuyến nghị vì nhanh hơn, giữ state)
2. Provider cloud mặc định là gì (OpenAI/Anthropic/Gemini) để làm ví dụ đầu
   tiên trong code?
3. Ollama model mặc định cho local provider (vd `llama3.1`, `qwen2.5-coder`)?

---

## 7. Cấu trúc thư mục project đề xuất

```
ai-shell-suggest/
├── Cargo.toml
├── src/
│   ├── main.rs              # entrypoint daemon
│   ├── daemon/
│   │   ├── socket.rs        # unix socket server
│   │   └── session.rs
│   ├── context/
│   │   ├── collector.rs     # thu thập cwd, git, history
│   │   └── mod.rs
│   ├── provider/
│   │   ├── mod.rs           # trait AiProvider
│   │   ├── cloud.rs         # OpenAI/Anthropic/Gemini
│   │   └── local.rs         # Ollama/llama.cpp
│   └── config.rs
├── shell/
│   └── zsh/
│       └── ai-suggest.plugin.zsh   # ZLE widget script
└── README.md
```
