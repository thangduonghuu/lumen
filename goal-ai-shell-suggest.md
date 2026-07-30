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

- [ ] Rust daemon chạy nền, giao tiếp qua unix socket
- [ ] Zsh widget bắt sự kiện gõ, gửi context (buffer hiện tại + cwd) tới daemon
- [ ] Daemon gọi 1 provider AI (chọn cloud HOẶC local qua config) → trả gợi ý
- [ ] Hiển thị popup đơn giản dưới dòng lệnh, điều hướng bằng phím mũi tên
- [ ] Chọn gợi ý bằng Tab/Enter để chèn vào dòng lệnh
- [ ] File config cơ bản: chọn provider, API key, model

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
