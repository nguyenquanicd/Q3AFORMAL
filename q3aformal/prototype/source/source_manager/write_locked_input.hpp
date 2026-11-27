#pragma once

#include <array>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <istream>
#include <io.h>
#include <memory>
#include <share.h>
#include <stdexcept>
#include <streambuf>

namespace q3a {

// Hash and parse through the same Windows handle. Sharing permits readers
// while denying writers until verification finishes.
class WriteLockedInput final : private std::streambuf {
public:
    explicit WriteLockedInput(const std::filesystem::path& path)
        : file_(_wfsopen(path.c_str(), L"rb", _SH_DENYWR), &std::fclose),
          input_(this) {
        if (!file_) {
            throw std::runtime_error("cannot open input for reading with writes denied: " +
                                     path.u8string());
        }
    }

    std::istream& stream() noexcept { return input_; }
    std::intptr_t native_handle() const noexcept { return _get_osfhandle(_fileno(file_.get())); }

    void rewind() {
        if (std::fseek(file_.get(), 0, SEEK_SET) != 0) {
            throw std::runtime_error("cannot rewind input");
        }
        setg(nullptr, nullptr, nullptr);
        input_.clear();
    }

private:
    pos_type seekoff(off_type offset, std::ios_base::seekdir direction,
                     std::ios_base::openmode mode) override {
        if (!(mode & std::ios_base::in)) return pos_type(off_type(-1));
        if (direction == std::ios_base::cur && offset == 0) {
            const auto physical = _ftelli64(file_.get());
            if (physical < 0) return pos_type(off_type(-1));
            return pos_type(physical - unread_bytes());
        }
        if (direction != std::ios_base::beg && direction != std::ios_base::end) {
            return pos_type(off_type(-1));
        }
        const int origin = direction == std::ios_base::beg ? SEEK_SET : SEEK_END;
        if (_fseeki64(file_.get(), offset, origin) != 0) return pos_type(off_type(-1));
        setg(nullptr, nullptr, nullptr);
        return pos_type(_ftelli64(file_.get()));
    }

    pos_type seekpos(pos_type position, std::ios_base::openmode mode) override {
        return seekoff(static_cast<off_type>(position), std::ios_base::beg, mode);
    }

    std::ptrdiff_t unread_bytes() const {
        return gptr() == nullptr ? 0 : egptr() - gptr();
    }

    int_type underflow() override {
        if (gptr() != egptr()) return traits_type::to_int_type(*gptr());
        const auto count = std::fread(buffer_.data(), 1, buffer_.size(), file_.get());
        if (std::ferror(file_.get())) {
            throw std::runtime_error("failed while reading locked input");
        }
        if (count == 0) return traits_type::eof();
        setg(buffer_.data(), buffer_.data(), buffer_.data() + count);
        return traits_type::to_int_type(*gptr());
    }

    std::unique_ptr<std::FILE, decltype(&std::fclose)> file_;
    std::array<char, 64 * 1024> buffer_;
    std::istream input_;
};

} // namespace q3a
