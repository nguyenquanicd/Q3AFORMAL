#include "indexed_trace.hpp"

#include <algorithm>
#include <array>
#include <iomanip>
#include <istream>
#include <ostream>
#include <set>
#include <stdexcept>

namespace q3a::trace {
namespace {

constexpr std::array<char, 8> kMagic{'Q', '3', 'A', 'T', 'R', 'C', '1', '\n'};
constexpr std::uint64_t kBlockFrames = 256;
constexpr std::uint64_t kRecordBytes = 12;
constexpr std::uint64_t kMaximumFrames = 10001;
constexpr std::uint64_t kMaximumSignals = 100000;
constexpr std::size_t kMaximumName = 4096;
constexpr std::size_t kMaximumDictionaryBytes = 16 * 1024 * 1024;

struct Signal {
    std::string name;
    std::uint64_t width;
};

[[noreturn]] void invalid(const char* message) {
    throw std::invalid_argument(std::string("indexed trace: ") + message);
}

void write_number(std::ostream& output, std::uint64_t value, std::size_t bytes = 8) {
    std::array<char, 8> data{};
    for (std::size_t i = 0; i < bytes; ++i) {
        data[i] = static_cast<char>((value >> (8 * i)) & 255);
    }
    output.write(data.data(), static_cast<std::streamsize>(bytes));
}

std::uint64_t read_number(std::istream& input, std::size_t bytes = 8) {
    std::array<unsigned char, 8> data{};
    if (!input.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(bytes))) {
        invalid("truncated integer");
    }
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < bytes; ++i) value |= std::uint64_t{data[i]} << (8 * i);
    return value;
}

bool valid_name(const std::string& name) {
    return !name.empty() && name.size() <= kMaximumName &&
        std::all_of(name.begin(), name.end(), [](unsigned char ch) { return ch >= 0x21 && ch <= 0x7e; });
}

void write_name(std::ostream& output, const std::string& name) {
    write_number(output, name.size(), 4);
    output.write(name.data(), static_cast<std::streamsize>(name.size()));
}

std::string read_name(std::istream& input, std::size_t& dictionary_bytes) {
    const auto length = read_number(input, 4);
    if (length > kMaximumName || length > kMaximumDictionaryBytes - dictionary_bytes) {
        invalid("dictionary size limit exceeded");
    }
    std::string name(static_cast<std::size_t>(length), '\0');
    if (!input.read(name.data(), static_cast<std::streamsize>(length)) || !valid_name(name)) {
        invalid("invalid signal or property name");
    }
    dictionary_bytes += name.size();
    return name;
}

bool fits(std::uint64_t value, std::uint64_t width) {
    return width == 64 || (value >> width) == 0;
}

class IndexedReader {
public:
    explicit IndexedReader(std::istream& input) : input_(input) {
        input_.seekg(0, std::ios::end);
        const auto end = input_.tellg();
        if (end < 0) invalid("cannot determine file length");
        const auto size = static_cast<std::uint64_t>(end);
        seek(0);
        std::array<char, kMagic.size()> magic{};
        if (!input_.read(magic.data(), magic.size()) || magic != kMagic) invalid("unsupported format");
        frame_count = read_number(input_);
        candidate = read_number(input_);
        const auto signal_count = read_number(input_, 4);
        if (frame_count == 0 || frame_count > kMaximumFrames || candidate >= frame_count ||
            signal_count == 0 || signal_count > kMaximumSignals) invalid("invalid dimensions");
        std::size_t dictionary_bytes = 0;
        property = read_name(input_, dictionary_bytes);
        signals.reserve(static_cast<std::size_t>(signal_count));
        for (std::uint64_t i = 0; i < signal_count; ++i) {
            auto name = read_name(input_, dictionary_bytes);
            const auto width = read_number(input_, 4);
            if (width == 0 || width > 64 || (!signals.empty() && signals.back().name >= name)) {
                invalid("invalid width or unordered signal dictionary");
            }
            signals.push_back({std::move(name), width});
        }
        const auto dictionary_end = input_.tellg();
        if (dictionary_end < 0) invalid("truncated dictionary");
        const auto block_count = (frame_count + kBlockFrames - 1) / kBlockFrames;
        const auto table_bytes = (block_count + 1) * 8;
        if (size < table_bytes || size - table_bytes < static_cast<std::uint64_t>(dictionary_end)) {
            invalid("truncated block index");
        }
        const auto index_start = size - table_bytes;
        seek(index_start);
        for (std::uint64_t i = 0; i <= block_count; ++i) {
            const auto offset = read_number(input_);
            const auto minimum_block = series_index_bytes() + signal_count * kRecordBytes;
            if (offset > index_start ||
                (i == 0 && offset != static_cast<std::uint64_t>(dictionary_end)) ||
                (i != 0 && (offset < blocks_.back() || offset - blocks_.back() < minimum_block))) {
                invalid("invalid block offset");
            }
            blocks_.push_back(offset);
        }
        if (blocks_.back() != index_start) invalid("invalid block index boundary");
    }

    void write_changes(std::ostream& output, std::size_t signal_id,
                       std::uint64_t first, std::uint64_t last) {
        bool first_change = true;
        std::uint64_t last_value = 0;
        for (auto block = first / kBlockFrames; block <= last / kBlockFrames; ++block) {
            const auto base_frame = block * kBlockFrames;
            std::uint64_t value = 0;
            const auto window_first = std::max(first, base_frame);
            bool emitted_start = false;
            read_series(block, signal_id, [&](std::uint64_t frame, std::uint64_t next) {
                const auto absolute = base_frame + frame;
                if (absolute > window_first && !emitted_start) {
                    emit(output, window_first, value, first_change, last_value);
                    emitted_start = true;
                }
                value = next;
                if (absolute > window_first && absolute <= last) {
                    emit(output, absolute, value, first_change, last_value);
                }
            });
            if (!emitted_start) emit(output, window_first, value, first_change, last_value);
        }
    }

    template <typename Visit>
    void read_series(std::uint64_t block, std::size_t signal_id, Visit visit) {
        const auto start = blocks_[block];
        const auto table = blocks_[block + 1] - series_index_bytes();
        seek(table + signal_id * 8);
        const auto offset = read_number(input_);
        const auto end = read_number(input_);
        const auto length = validate_series(block, signal_id, offset, end);
        seek(start + offset);
        read_records(block, signal_id, length, visit);
    }

    void read_block(std::uint64_t block, std::vector<std::uint64_t>& values) {
        const auto start = blocks_[block];
        seek(blocks_[block + 1] - series_index_bytes());
        std::vector<std::uint64_t> offsets;
        offsets.reserve(signals.size() + 1);
        for (std::size_t i = 0; i <= signals.size(); ++i) offsets.push_back(read_number(input_));
        seek(start);
        const auto block_frames = samples_in(block);
        for (std::size_t id = 0; id < signals.size(); ++id) {
            const auto length = validate_series(block, id, offsets[id], offsets[id + 1]);
            const auto base = values.begin() + id * block_frames;
            std::uint64_t previous_frame = 0;
            std::uint64_t previous_value = 0;
            read_records(block, id, length, [&](std::uint64_t frame, std::uint64_t value) {
                std::fill(base + previous_frame, base + frame, previous_value);
                previous_frame = frame;
                previous_value = value;
            });
            std::fill(base + previous_frame, base + block_frames, previous_value);
        }
    }

    std::uint64_t samples_in(std::uint64_t block) const {
        return std::min(kBlockFrames, frame_count - block * kBlockFrames);
    }

    std::uint64_t frame_count = 0;
    std::uint64_t candidate = 0;
    std::string property;
    std::vector<Signal> signals;

private:
    std::uint64_t validate_series(std::uint64_t block, std::size_t id,
                                  std::uint64_t begin, std::uint64_t end) const {
        const auto limit = blocks_[block + 1] - blocks_[block] - series_index_bytes();
        const auto length = end >= begin ? end - begin : 0;
        if (end > limit || length == 0 || length % kRecordBytes != 0 ||
            length / kRecordBytes > samples_in(block) ||
            (id == 0 && begin != 0) || (id + 1 == signals.size() && end != limit)) {
            invalid("invalid signal record offsets");
        }
        return length;
    }

    template <typename Visit>
    void read_records(std::uint64_t block, std::size_t id, std::uint64_t length, Visit visit) {
        std::uint64_t previous_frame = 0;
        for (std::uint64_t record = 0; record < length / kRecordBytes; ++record) {
            const auto frame = read_number(input_, 4);
            const auto value = read_number(input_);
            if (frame >= samples_in(block) || (record == 0 && frame != 0) ||
                (record != 0 && frame <= previous_frame) || !fits(value, signals[id].width)) {
                invalid("invalid signal change record");
            }
            previous_frame = frame;
            visit(frame, value);
        }
    }

    static void emit(std::ostream& output, std::uint64_t frame, std::uint64_t value,
                     bool& first_change, std::uint64_t& last_value) {
        if (!first_change && value == last_value) return;
        if (!first_change) output << ',';
        output << '[' << frame << ",\"0x" << std::hex << value << std::dec << "\"]";
        first_change = false;
        last_value = value;
    }

    std::uint64_t series_index_bytes() const { return (signals.size() + 1) * 8; }

    void seek(std::uint64_t offset) {
        if (!input_.seekg(static_cast<std::streamoff>(offset))) invalid("cannot seek to record");
    }

    std::istream& input_;
    std::vector<std::uint64_t> blocks_;
};

} // namespace

void write_indexed_trace(std::ostream& output, const lowering::TIRModule& model,
                         const std::vector<replay::Frame>& frames,
                         const std::string& property, std::uint64_t candidate) {
    if (frames.empty() || frames.size() > kMaximumFrames || candidate >= frames.size() ||
        model.signals.empty() || model.signals.size() > kMaximumSignals || !valid_name(property)) {
        invalid("invalid witness dimensions");
    }
    std::vector<Signal> signals;
    std::size_t dictionary_bytes = property.size();
    for (const auto& signal : model.signals) {
        if (!valid_name(signal.name) || signal.width == 0 || signal.width > 64 ||
            signal.name.size() > kMaximumDictionaryBytes - dictionary_bytes) {
            invalid("unsupported witness signal identity or width");
        }
        dictionary_bytes += signal.name.size();
        signals.push_back({signal.name, signal.width});
    }
    std::sort(signals.begin(), signals.end(), [](const auto& a, const auto& b) { return a.name < b.name; });
    for (std::size_t i = 1; i < signals.size(); ++i) {
        if (signals[i - 1].name == signals[i].name) invalid("duplicate witness signal");
    }
    output.write(kMagic.data(), kMagic.size());
    write_number(output, frames.size());
    write_number(output, candidate);
    write_number(output, signals.size(), 4);
    write_name(output, property);
    for (const auto& signal : signals) {
        write_name(output, signal.name);
        write_number(output, signal.width, 4);
    }
    std::uint64_t position = kMagic.size() + 8 + 8 + 4 + 4 + dictionary_bytes + 8 * signals.size();
    std::vector<std::uint64_t> blocks;
    std::vector<std::uint64_t> offsets;
    offsets.reserve(signals.size() + 1);
    for (std::size_t start = 0; start < frames.size(); start += kBlockFrames) {
        blocks.push_back(position);
        offsets.clear();
        std::uint64_t bytes = 0;
        const auto end = std::min<std::size_t>(frames.size(), start + kBlockFrames);
        for (const auto& signal : signals) {
            offsets.push_back(bytes);
            std::uint64_t previous = 0;
            for (auto frame = start; frame < end; ++frame) {
                const auto value = frames[frame].at(signal.name);
                if (!fits(value, signal.width)) invalid("witness value exceeds signal width");
                if (frame == start || value != previous) {
                    write_number(output, frame - start, 4);
                    write_number(output, value);
                    bytes += kRecordBytes;
                }
                previous = value;
            }
        }
        offsets.push_back(bytes);
        for (auto offset : offsets) write_number(output, offset);
        position += bytes + 8 * offsets.size();
        if (!output) throw std::runtime_error("cannot write indexed witness");
    }
    blocks.push_back(position);
    for (auto offset : blocks) write_number(output, offset);
    if (!output) throw std::runtime_error("cannot write indexed witness index");
}

void write_indexed_window(std::istream& input, std::ostream& output,
                          std::uint64_t first, std::uint64_t last,
                          const std::vector<std::string>& names) {
    IndexedReader reader(input);
    if (first > last || last >= reader.frame_count) invalid("window exceeds the trace frame range");
    std::vector<std::size_t> selected;
    std::set<std::string> seen;
    for (const auto& name : names) {
        const auto found = std::lower_bound(reader.signals.begin(), reader.signals.end(), name,
            [](const Signal& signal, const std::string& key) { return signal.name < key; });
        if (found == reader.signals.end() || found->name != name) invalid("unknown signal selection");
        if (!seen.insert(name).second) invalid("duplicate signal selection");
        selected.push_back(static_cast<std::size_t>(found - reader.signals.begin()));
    }
    if (selected.empty()) {
        for (std::size_t id = 0; id < reader.signals.size(); ++id) selected.push_back(id);
    }
    output << "{\"schema\":\"Q3A-TRACE-WINDOW-1\",\"property\":" << std::quoted(reader.property)
           << ",\"candidate_frame\":" << reader.candidate << ",\"frame_count\":" << reader.frame_count
           << ",\"first\":" << first << ",\"last\":" << last << ",\"signals\":[";
    for (std::size_t i = 0; i < selected.size(); ++i) {
        if (i != 0) output << ',';
        const auto id = selected[i];
        const auto& signal = reader.signals[id];
        output << "{\"id\":" << id << ",\"name\":" << std::quoted(signal.name)
               << ",\"width\":" << signal.width << ",\"changes\":[";
        reader.write_changes(output, id, first, last);
        output << "]}";
    }
    output << "]}\n";
    if (!output) throw std::runtime_error("cannot write indexed trace window");
}

std::optional<std::uint64_t> find_indexed_transition(std::istream& input, const std::string& name,
                                                    std::uint64_t cursor, bool forward) {
    IndexedReader reader(input);
    if (cursor >= reader.frame_count) invalid("cursor exceeds the trace frame range");
    const auto found = std::lower_bound(reader.signals.begin(), reader.signals.end(), name,
        [](const Signal& signal, const std::string& key) { return signal.name < key; });
    if (found == reader.signals.end() || found->name != name) invalid("unknown signal selection");
    const auto id = static_cast<std::size_t>(found - reader.signals.begin());
    auto block = cursor / kBlockFrames;
    if (forward) {
        std::optional<std::uint64_t> value, next;
        const auto last_block = (reader.frame_count - 1) / kBlockFrames;
        for (; block <= last_block && !next; ++block) {
            reader.read_series(block, id, [&](std::uint64_t frame, std::uint64_t sample) {
                const auto absolute = block * kBlockFrames + frame;
                if (!next && value && *value != sample && absolute > cursor) next = absolute;
                value = sample;
            });
        }
        return next;
    }

    for (;;) {
        const auto base = block * kBlockFrames;
        std::uint64_t first_value{};
        std::optional<std::uint64_t> previous;
        reader.read_series(block, id, [&](std::uint64_t frame, std::uint64_t sample) {
            if (frame == 0) first_value = sample;
            else if (base + frame < cursor) previous = base + frame;
        });
        if (previous || block == 0) return previous;
        if (base < cursor) {
            std::uint64_t last_previous{};
            reader.read_series(block - 1, id, [&](std::uint64_t, std::uint64_t sample) {
                last_previous = sample;
            });
            if (last_previous != first_value) return base;
        }
        --block;
    }
}

void visit_indexed_witness(
    std::istream& input, const lowering::TIRModule& model, const std::string& property,
    std::optional<std::size_t> expected_frames, const std::function<void(std::uint64_t)>& check_memory,
    const std::function<void(const replay::FrameView&, std::size_t)>& visit) {
    IndexedReader reader(input);
    const auto frame_count = static_cast<std::size_t>(reader.frame_count);
    if (reader.property != property || (expected_frames && frame_count != *expected_frames) ||
        reader.signals.size() != model.signals.size()) invalid("witness and model identities differ");
    const auto signal_count = reader.signals.size();
    for (const auto& signal : model.signals) {
        const auto match = std::lower_bound(reader.signals.begin(), reader.signals.end(), signal.name,
            [](const Signal& entry, const std::string& name) { return entry.name < name; });
        if (match == reader.signals.end() || match->name != signal.name || match->width != signal.width) {
            invalid("witness signal dictionary differs from model");
        }
    }

    struct Block {
        std::size_t id = static_cast<std::size_t>(-1);
        std::vector<std::uint64_t> values;
    };
    struct Sample {
        std::size_t index = static_cast<std::size_t>(-1);
        replay::Frame values;
    };
    std::array<Block, 2> blocks;
    std::array<Sample, 2> samples;
    check_memory(signal_count * 256);
    for (auto& sample : samples) {
        for (const auto& signal : reader.signals) sample.values.emplace(signal.name, 0);
    }
    const replay::FrameView frames(frame_count, [&](std::size_t frame) -> const replay::Frame& {
        if (frame >= frame_count) invalid("witness frame does not exist");
        auto& sample = samples[frame % samples.size()];
        if (sample.index == frame) return sample.values;
        const auto block_id = frame / kBlockFrames;
        auto& block = blocks[block_id % blocks.size()];
        if (block.id != block_id) {
            const auto count = signal_count * reader.samples_in(block_id);
            const auto additional = count > block.values.capacity() ? count : 0;
            check_memory((additional + signal_count + 1) * sizeof(std::uint64_t));
            block.values.resize(static_cast<std::size_t>(count));
            reader.read_block(block_id, block.values);
            block.id = block_id;
        }
        const auto block_frames = block.values.size() / signal_count;
        const auto offset = frame % kBlockFrames;
        std::size_t id = 0;
        for (auto& entry : sample.values) entry.second = block.values[id++ * block_frames + offset];
        sample.index = frame;
        return sample.values;
    });
    visit(frames, static_cast<std::size_t>(reader.candidate));
}

} // namespace q3a::trace
