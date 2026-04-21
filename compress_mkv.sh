#!/usr/bin/env bash

# Script to compress MKV files to 10 Mbps MP4 using ffmpeg
# Supports both SDR and HDR output, including batch processing directories

set -e

# Check if a filename was provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input> [--sdr] [--gpu]"
    echo ""
    echo "Options:"
    echo "  <input>       Path to input MKV file or directory"
    echo "  --sdr         Force SDR output (tone mapping from HDR input)"
    echo "                If not specified, outputs HDR10 (10-bit color)"
    echo "  --gpu         Use GPU hardware acceleration (VAAPI)"
    echo ""
    echo "Note: Output is always in MKV format to preserve multiple audio tracks"
    echo ""
    echo "Examples:"
    echo "  $0 movie.mkv                           # Compress to HDR10"
    echo "  $0 movie.mkv --sdr                      # Compress to SDR (tone mapped)"
    echo "  $0 movie.mkv --gpu                      # Use GPU acceleration"
    echo "  $0 movie.mkv --overwrite               # Skip backup, overwrite existing output"
    echo "  $0 /path/to/show/                      # Compress all MKV files in directory"
    exit 1
fi

output_sdr=false
overwrite=false
gpu=""
input_path=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --sdr)
            output_sdr=true
            ;;
        --overwrite)
            overwrite=true
            ;;
        --gpu)
            gpu="vaapi"
            ;;
        *)
            if [ -z "$input_path" ]; then
                input_path="$1"
            else
                echo "Error: Unexpected argument '$1'"
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$input_path" ]; then
    echo "Error: No input path provided."
    exit 1
fi

# Check if the input exists
if [ ! -e "$input_path" ]; then
    echo "Error: Input path '$input_path' does not exist."
    exit 1
fi

# Persistent skip list (absolute paths, one per line) stored in the directory
# the script is invoked from. Files listed here are skipped on future runs —
# typically because a previous run couldn't shrink them past the reduction
# threshold.
skip_list_file="$(pwd)/compress_mkv_skip.txt"

# Get list of MKV files
if [ -d "$input_path" ]; then
    echo "======================================"
    echo "MKV Compression Tool"
    echo "======================================"
    echo "Directory mode detected"
    echo "Input:  $input_path"
    echo "Traversing up to 2 levels deep for MKV files..."

    # Find all .mkv files up to 2 levels deep, pruning any directory tree that
    # contains a `nocompress` marker file.
    mkv_files=()
    while IFS= read -r -d '' file; do
        mkv_files+=("$file")
    done < <(find "$input_path" -maxdepth 2 \( -type d -exec test -e '{}/nocompress' \; -prune \) -o -type f -name "*.mkv" -print0)

    # Check if any files were found
    if [ ${#mkv_files[@]} -eq 0 ]; then
        echo "Error: No MKV files found in directory '$input_path'."
        exit 1
    fi

    echo "Found ${#mkv_files[@]} MKV file(s)"
    echo ""
    echo "Files to process:"
    for file in "${mkv_files[@]}"; do
        echo "  - $file"
    done
    echo ""

    # Ask for confirmation
    echo "Do you want to convert these files? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
    echo "Starting batch compression..."
    echo ""
else
    # Single file mode
    if [ ! -f "$input_path" ]; then
        echo "Error: Path '$input_path' is not a file."
        exit 1
    fi
    mkv_files=("$input_path")
fi

# Check if input file is actually an MKV (single file mode only)
if [ -f "$input_path" ] && [[ ! "$input_path" =~ \.mkv$ ]]; then
    echo "Warning: Input file doesn't have .mkv extension. Proceeding anyway..."
fi

# Detect if a file has interlaced video
is_interlaced() {
    local field_order
    field_order=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of csv=s=x:p=0 "$1" 2>/dev/null)
    [[ "$field_order" == "tt" || "$field_order" == "bb" || "$field_order" == "tb" || "$field_order" == "bt" ]]
}

# Detect if a file has HDR color transfer characteristics
is_hdr() {
    local transfer
    transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=s=x:p=0 "$1" 2>/dev/null)
    # smpte2084 = PQ (HDR10), arib-std-b67 = HLG
    [[ "$transfer" == "smpte2084" || "$transfer" == "arib-std-b67" ]]
}

# Check for a `nocompress` marker file in the file's directory or any ancestor
# directory up to (and including) the top-level input path. Used so users can
# drop a `nocompress` file next to (or above) any mkv they want left alone.
has_nocompress_marker() {
    local file_dir root_abs dir
    file_dir=$(cd "$(dirname "$1")" && pwd -P)
    root_abs=$(cd "$2" && pwd -P)
    dir="$file_dir"
    while :; do
        if [ -e "$dir/nocompress" ]; then
            return 0
        fi
        if [ "$dir" = "$root_abs" ] || [ "$dir" = "/" ]; then
            return 1
        fi
        dir=$(dirname "$dir")
    done
}

# Determine bitrate based on resolution
get_quality_settings() {
    local resolution
    resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2>/dev/null)

    if [ -z "$resolution" ]; then
        echo "20 10M 20M"
        return
    fi

    local width height
    IFS='x' read -r width height <<< "$resolution"

    # Returns: crf maxrate bufsize skip_bitrate
    if [ "$width" -ge 3840 ]; then
        echo "20 32M 64M 25M"   # 4K
    elif [ "$width" -ge 1920 ]; then
        echo "20 16M 32M 10M"   # 1080p
    elif [ "$width" -ge 1280 ]; then
        echo "20 8M 16M 4M"     # 720p
    else
        echo "20 4M 8M 2M"      # DVD (480p/576p)
    fi
}

# Display compression info (for single file)
if [ ${#mkv_files[@]} -eq 1 ]; then
    read -r crf maxrate bufsize skip_bitrate <<< "$(get_quality_settings "$input_path")"

    if $output_sdr && is_hdr "$input_path"; then
        mode_text="SDR output (HDR→SDR tone mapping)"
    elif is_hdr "$input_path"; then
        mode_text="HDR10 passthrough"
    else
        mode_text="SDR output"
    fi

    echo "======================================"
    echo "MKV Compression Tool"
    echo "======================================"
    echo "Input:  $input_path"
    echo "Mode:   $mode_text"
    echo "CRF:    $crf (maxrate: $maxrate)"
    echo "======================================"
    echo "Starting compression..."
fi

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed. Please install it first."
    exit 1
fi

# Process files
total_files=${#mkv_files[@]}
success_count=0
total_before=0
total_after=0

for input_file in "${mkv_files[@]}"; do
    if [ ${#mkv_files[@]} -gt 1 ]; then
        echo ""
        echo "Processing file $((success_count + 1)) of $total_files:"
        echo "  $input_file"
    fi

    # Skip if a `nocompress` marker exists in this file's directory or any
    # ancestor up to the input root.
    if [ -d "$input_path" ]; then
        nocompress_root="$input_path"
    else
        nocompress_root=$(dirname "$input_file")
    fi
    if has_nocompress_marker "$input_file" "$nocompress_root"; then
        echo "Skipping $input_file (nocompress marker found)"
        success_count=$((success_count + 1))
        continue
    fi

    # Get quality settings based on resolution
    read -r crf maxrate bufsize skip_bitrate <<< "$(get_quality_settings "$input_file")"

    # Skip if already compressed by this script
    compressed_tag=$(ffprobe -v error -show_entries format_tags=COMPRESSED_BY -of csv=p=0 "$input_file" 2>/dev/null)
    if [ "$compressed_tag" = "compress_mkv" ]; then
        echo "Skipping $input_file (already compressed)"
        success_count=$((success_count + 1))
        continue
    fi

    # Skip if a previous run added this file to the persistent skip list
    input_abs="$(cd "$(dirname "$input_file")" && pwd -P)/$(basename "$input_file")"
    if [ -f "$skip_list_file" ] && grep -Fxq -- "$input_abs" "$skip_list_file"; then
        echo "Skipping $input_file (in $skip_list_file)"
        success_count=$((success_count + 1))
        continue
    fi

    # Skip if source bitrate is already at or below the threshold for this resolution
    src_bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$input_file" 2>/dev/null | tr -d ',[:space:]')
    if [[ ! "$src_bitrate" =~ ^[0-9]+$ ]]; then
        # Fall back to container-level bitrate if per-stream is unavailable
        src_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$input_file" 2>/dev/null | tr -d ',[:space:]')
    fi
    skip_bitrate_bps=$(numfmt --from=iec "$skip_bitrate" 2>/dev/null)
    if [[ "$src_bitrate" =~ ^[0-9]+$ ]] && [ -n "$skip_bitrate_bps" ] && [ "$src_bitrate" -le "$skip_bitrate_bps" ]; then
        echo "Skipping $input_file (source bitrate $(numfmt --to=iec "$src_bitrate")bps <= threshold ${skip_bitrate}bps)"
        success_count=$((success_count + 1))
        continue
    fi

    # Track file size before compression
    before_size=$(stat -c '%s' "$input_file" 2>/dev/null || stat -f '%z' "$input_file")
    total_before=$((total_before + before_size))

    echo "Starting compression..."

    # Write to a local temp file to avoid NFS write latency during encoding
    tmp_output=$(mktemp "/tmp/compress_mkv_XXXXXX.mkv")
    rm "$tmp_output"

    # Detect if input is HDR
    input_is_hdr=false
    if is_hdr "$input_file"; then
        input_is_hdr=true
    fi

    # Detect if input is interlaced
    input_is_interlaced=false
    if is_interlaced "$input_file"; then
        input_is_interlaced=true
        echo "Interlaced input detected, will deinterlace"
    fi

    # Set encoder and hw options based on GPU flag
    hw_init=""
    encoder="libx265"
    deinterlace="yadif"
    sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
    hdr_vf=""
    sdr_plain_vf=""
    hdr_extra=(-pix_fmt yuv420p10le -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")

    if [ "$gpu" = "vaapi" ]; then
        hw_init="-vaapi_device /dev/dri/renderD128"
        encoder="hevc_vaapi"
        deinterlace="yadif"
        sdr_vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=nv12,hwupload"
        hdr_vf="format=p010,hwupload"
        sdr_plain_vf="format=nv12,hwupload"
        hdr_extra=()
    fi

    # Prepend deinterlace filter if needed
    if $input_is_interlaced; then
        sdr_vf="$deinterlace,$sdr_vf"
        if [ -n "$hdr_vf" ]; then
            hdr_vf="$deinterlace,$hdr_vf"
        else
            hdr_vf="$deinterlace"
        fi
        if [ -n "$sdr_plain_vf" ]; then
            sdr_plain_vf="$deinterlace,$sdr_plain_vf"
        else
            sdr_plain_vf="$deinterlace"
        fi
    fi

    # Check if English subtitles exist
    sub_map=()
    sub_codec=()
    if ffprobe -v error -select_streams s -show_entries stream_tags=language -of csv=p=0 "$input_file" 2>/dev/null | grep -q "eng"; then
        sub_map=(-map "0:s:m:language:eng")
        sub_codec=(-c:s copy)
    fi

    # Determine output mode
    # Set quality args based on encoder type
    if [ "$gpu" = "vaapi" ]; then
        quality_args=(-rc_mode CQP -global_quality "$crf" -maxrate "$maxrate" -bufsize "$bufsize")
    else
        quality_args=(-crf "$crf" -maxrate "$maxrate" -bufsize "$bufsize")
    fi

    metadata=(-metadata "COMPRESSED_BY=compress_mkv")

    if $output_sdr && $input_is_hdr; then
        echo "Mode: SDR output (HDR→SDR tone mapping)"
        ffmpeg $hw_init -i "$input_file" \
            -map 0:v -map 0:a:m:language:eng "${sub_map[@]}" \
            "${quality_args[@]}" \
            -vf "$sdr_vf" \
            -c:v "$encoder" \
            -c:a copy "${sub_codec[@]}" \
            "${metadata[@]}" \
            "$tmp_output"
    elif $input_is_hdr; then
        echo "Mode: HDR10 passthrough (preserving HDR metadata)"
        ffmpeg $hw_init -i "$input_file" \
            -map 0:v -map 0:a:m:language:eng "${sub_map[@]}" \
            "${quality_args[@]}" \
            ${hdr_vf:+-vf "$hdr_vf"} \
            -c:v "$encoder" \
            "${hdr_extra[@]}" \
            -color_primaries bt2020 \
            -color_trc smpte2084 \
            -colorspace bt2020nc \
            -c:a copy "${sub_codec[@]}" \
            "${metadata[@]}" \
            "$tmp_output"
    else
        echo "Mode: SDR output"
        ffmpeg $hw_init -i "$input_file" -map 0:v -map 0:a:m:language:eng "${sub_map[@]}" "${quality_args[@]}" ${sdr_plain_vf:+-vf "$sdr_plain_vf"} -c:v "$encoder" -c:a copy "${sub_codec[@]}" "${metadata[@]}" "$tmp_output"
    fi

    # Verify the compressed output achieves at least 33% size reduction
    tmp_size=$(stat -c '%s' "$tmp_output" 2>/dev/null || stat -f '%z' "$tmp_output")
    reduction_pct=$(( (before_size - tmp_size) * 100 / before_size ))
    if [ "$reduction_pct" -lt 33 ]; then
        echo "Insufficient reduction: $(numfmt --to=iec "$before_size") -> $(numfmt --to=iec "$tmp_size") (${reduction_pct}%, need >=33%). Discarding compressed file, keeping original."
        rm "$tmp_output"

        # Record this file so future runs skip it.
        echo "$input_abs" >> "$skip_list_file"
        echo "Added to skip list: $skip_list_file"

        total_after=$((total_after + before_size))
        success_count=$((success_count + 1))
        echo ""
        continue
    fi

    # Copy compressed file to final location, preserving original creation timestamp
    original_ts=$(stat -c '%Y' "$input_file" 2>/dev/null || stat -f '%m' "$input_file")
    if [ "$overwrite" = true ]; then
        echo "Copying to final location..."
        rsync --progress "$tmp_output" "$input_file" && rm "$tmp_output"
        touch -d "@$original_ts" "$input_file" 2>/dev/null || touch -t "$(date -r "$original_ts" '+%Y%m%d%H%M.%S')" "$input_file"
    else
        output_file="${input_file%.mkv}_compressed.mkv"
        echo "Copying to final location..."
        rsync --progress "$tmp_output" "$output_file" && rm "$tmp_output"
        touch -d "@$original_ts" "$output_file" 2>/dev/null || touch -t "$(date -r "$original_ts" '+%Y%m%d%H%M.%S')" "$output_file"
        echo "Output: $output_file"
    fi

    # Track file size after compression
    if [ "$overwrite" = true ]; then
        after_size=$(stat -c '%s' "$input_file" 2>/dev/null || stat -f '%z' "$input_file")
    else
        after_size=$(stat -c '%s' "$output_file" 2>/dev/null || stat -f '%z' "$output_file")
    fi
    total_after=$((total_after + after_size))
    saved=$((before_size - after_size))
    pct=$((saved * 100 / before_size))
    echo "Size: $(numfmt --to=iec "$before_size") -> $(numfmt --to=iec "$after_size") (saved $(numfmt --to=iec "$saved"), ${pct}%)"

    success_count=$((success_count + 1))
    echo ""
done

echo ""
echo "======================================"
if [ ${#mkv_files[@]} -gt 1 ]; then
    echo "Batch compression complete!"
    echo "Processed: $success_count / $total_files files"
else
    echo "Compression complete!"
fi
if [ "$total_before" -gt 0 ]; then
    total_saved=$((total_before - total_after))
    total_pct=$((total_saved * 100 / total_before))
    echo "Total: $(numfmt --to=iec "$total_before") -> $(numfmt --to=iec "$total_after") (saved $(numfmt --to=iec "$total_saved"), ${total_pct}%)"
fi
echo "======================================"
