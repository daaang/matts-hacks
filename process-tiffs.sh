#!/usr/bin/env bash
# Copyright (c) 2015 The Regents of the University of Michigan.
# All Rights Reserved. Licensed according to the terms of the Revised
# BSD License. See LICENSE.txt for details.

##
# Process Images
#
# This has the following command-line arguments:
#
#     --with-bitonals     Bitonal TIFFs will be G4-compressed
#     --with-contones     Contone TIFFs will be converted to JP2s
#     --without-bitonals  Bitonal TIFFs will be ignored
#     --without-contones  Contone TIFFs will be ignored
#
# The first two are on by default.
#
# This will process all TIFFs inside a shipment. It only looks at images
# with the extension `.tif`, and it should be run *after* retagging.
#
# Depending on whether the image in question is bitonal or a contone,
# we'll either compress it with Group 4 or convert it to JPEG 2000.
#
# This script was first written on 16 July 2012 to replace these old
# scripts:
#
# - compress-tiffs.sh (compressed bitonals)
# - tiff2jp2.sh (converted contones to JP2):
#   - tiff-meta-extract.sh
#   - xmp-maker.sh
#   - xmp_uuidify.pl
# - delete-shadow-tiffs.sh (delete successfully-converted TIFFs)
#
# There was a lot of redundancy; we had to search for all TIFFs at least
# three times, and each was tested for bits-per-sample at least twice.
# More importantly, the contone conversion barely even worked.
#
# This script just goes through each TIFF, figures out what to do, and
# does it. If there is a problem, it echoes the problem and does not
# delete the original erroneous image. Otherwise, all originals are
# removed in the end.
#
# Bad images will stay on in the form of `12345678-error.tif`.

#VERBOSE_LOGGING="on"

# These three functions echo with a pretty colored asterisk to show how
# good or bad the message is.
echogood() {
  echo "[1;32m *[0m $@"
}

echobad() {
  echo "[1;31m *[0m $@"
}

echowarn() {
  echo "[1;33m *[0m $@"
}

echoverb() {
  if [ "$VERBOSE_LOGGING" = "on" ]; then
    echogood "$@"
  fi
}

# This ensures that a command is defined.
missing_command() {
  if [ -z "${1}" ]; then
    echobad "Abort! This required command cannot be found: ${2}"
    exit 1
  fi
}

# These are the basic commands I'll be using.
TIFFINFO="$(which tiffinfo)"
TIFFSET="$(which tiffset)"
TIFFCP="$(which tiffcp)"
EXIFTOOL="$(which exiftool)"
#JP2_CONV="$(which kdu_compress)"
JP2_CONV="/l/local/kakadu-7.2/bin/Linux-x86-64-gcc/kdu_compress"
if ! [ -e "$JP2_CONV" ]; then
  JP2_CONV="$(which kdu_compress)"
fi

# Try this specific install first, in case there are multiple versions.
IMAGEMAGICK="/usr/bin/convert"
if ! [ -e "$IMAGEMAGICK" ]; then
  # If it's not there, just do whatever like the others.
  IMAGEMAGICK="$(which convert)"
fi

# I need to ensure that those commands actually are installed on this
# machine. If they aren't, I can't move forward.
missing_command "$TIFFINFO"     "tiffinfo"
missing_command "$TIFFSET"      "tiffset"
missing_command "$TIFFCP"       "tiffcp"
missing_command "$EXIFTOOL"     "exiftool"
missing_command "$JP2_CONV"     "kdu_compress"
missing_command "$IMAGEMAGICK"  "convert (ImageMagick)"

# These are our JP2 conversion settings. I (Matt) have no idea what
# these do, but I lifted them directly from Aaron's script here:
#
#     /l/local/feed/lib/HTFeed/PackageType/UCM/ImageRemediate.pm
#
# The only exception is `JP2_LEVELS`, which should be the following:
#
#     max( 5, ceil(log_2( max(width, height) / 100 )) - 1 )
#
# I just used 5 because bash's math is not great (plus tiff2jp2.sh just
# used 5, so it can't be *that* bad of a shortcut). If you want to write
# an external script to calculate the levels, be my guest.
WIDTH_HEIGHT_AWK='/Image Width: [0-9]* Image Length: [0-9]*/'
JP2_LEVEL_MIN=5
JP2_LAYERS=8
JP2_ORDER=RLCP
JP2_USE_SOP=yes
JP2_USE_EPH=yes
JP2_MODES="RESET|RESTART|CAUSAL|ERTERM|SEGMARK"
JP2_SLOPE=42988

DATE_TIF="%Y:%m:%d %H:%M:%S"
DATE_JP2="%Y-%m-%dT%H:%M:%S"

PROCESS_BITONALS=""
PROCESS_CONTONES=""
RAM_PREFIX="/ram/process-tiffs-XXXXXXXX"

for arg in "$@"; do
  if [ "$arg" = "--with-bitonals" ]; then
    PROCESS_BITONALS=""
  elif [ "$arg" = "--with-contones" ]; then
    PROCESS_CONTONES=""
  elif [ "$arg" = "--without-bitonals" ]; then
    PROCESS_BITONALS="nope"
  elif [ "$arg" = "--without-contones" ]; then
    PROCESS_CONTONES="nope"
  else
    echowarn "Ignoring unknown argument: $arg"
  fi
done

# Loop through all the TIFFs.
find . -mindepth 2 -type f -a -name '*.tif'                            \
    | sed -e 's,^\./,,'                                                \
    | sort -u                                                          \
    | while read original_tiff; do

  # If we have "barcode/image.tif", we now have "barcode/image".
  name="${original_tiff%".tif"}"
  #metafile="${name}.txt"
  metafile="$(mktemp "${RAM_PREFIX}-metafile.txt")"
  badfile="${name}-error.tif"

  # Get the info exactly once.
  $TIFFINFO "$original_tiff" > "$metafile" 2> /dev/null

  # Figure out what sort of image this is.
  if grep -q 'Bits/Sample: 8' "$metafile"; then
    if [ -z "$PROCESS_CONTONES" ]; then
      # It's a contone, so we convert to JP2.
      echogood "Converting $original_tiff to JPEG 2000 ..."

      #sparse="${name}-sparse.tif"
      ramdir="$(mktemp -d "${RAM_PREFIX}")"
      sparse="${ramdir}/sparse.tif"
      icc_tif="${ramdir}/icc.tif"
      new_image="${ramdir}/new.jp2"
      final_image="${name}.jp2"

      # Get the width and height.
      width="$(awk "${WIDTH_HEIGHT_AWK} { print \$3 }" "$metafile")"
      height="$(awk "${WIDTH_HEIGHT_AWK} { print \$6 }" "$metafile")"

      # Figure out which is larger.
      if [[ $width -gt $height ]]; then
        size="$width"
      else
        size="$height"
      fi

      # Calculate appropriate Clevels.
      clevels="$(echo "l(${size}/100)/l(2)" | bc -l | sed 's/\..*$//')"

      if [[ $clevels -lt $JP2_LEVEL_MIN ]]; then
        # If the Clevels is less than our minimum, use the minimum
        # instead.
        clevels="$JP2_LEVEL_MIN"
      fi

      # We don't want any XMP metadata to be copied over on its own. If
      # it's been a while since we last ran exiftool, this might take a
      # second.
      echoverb "exiftool -XMP:All= > $sparse"
      if $EXIFTOOL "-XMP:All=" "-MakerNotes:All=" "$original_tiff"     \
          -o "$sparse" > /dev/null; then

        alpha_channel=false
        if grep -q 'Extra Samples: 1<unassoc-alpha>' "$metafile"; then
          alpha_channel=true
          if $IMAGEMAGICK "$sparse" -alpha off "$icc_tif"; then
            if ! mv "$icc_tif" "$sparse"; then
              rm "$icc_tif"
              echowarn "Couldn't remove alpha channel."
            fi

          else
            echowarn "Couldn't remove alpha channel."
          fi
        fi

        if grep -q 'ICC Profile: <present>' "$metafile"; then
          if $IMAGEMAGICK "$sparse" -strip "$icc_tif"; then
            if ! mv "$icc_tif" "$sparse"; then
              rm "$icc_tif"
              echowarn "Couldn't remove ICC profile."
            fi

          else
            echowarn "Couldn't remove ICC profile."
          fi
        fi

        if grep -q 'Samples/Pixel: 3' "$metafile"; then
          jp2_space='sRGB'

        else
          jp2_space='sLUM'
        fi

        # We have a TIFF with no XMP now. We try to convert it to JP2.
        # This will always take a second. Other than the initial loading
        # of exiftool libraries, this is the only JP2 step that takes
        # noticeable time.
        if $JP2_CONV -quiet -i "$sparse" -o "$new_image"               \
            "Clevels=$clevels"                                         \
            "Clayers=$JP2_LAYERS"                                      \
            "Corder=$JP2_ORDER"                                        \
            "Cuse_sop=$JP2_USE_SOP"                                    \
            "Cuse_eph=$JP2_USE_EPH"                                    \
            "Cmodes=$JP2_MODES"                                        \
            -no_weights                                                \
            -slope "$JP2_SLOPE"; then

          # If the original image has a date, we want it. If not, we
          # want to add the current date.
          if grep -q '^\s*DateTime:' "$metafile"; then
            datetime='-IFD0:ModifyDate>XMP-tiff:DateTime'
          else
            datetime="-XMP-tiff:DateTime=$(date "+${DATE_JP2}")"
          fi
          rm "$metafile"

          # We have our JP2; we can remove the middle TIFF. Then we try
          # to grab metadata from the original TIFF. This should be very
          # quick since we just used exiftool a few lines back.
          if $EXIFTOOL -tagsFromFile "$original_tiff"                  \
              "-XMP-dc:source=${final_image}"                          \
              "-XMP-tiff:Compression=JPEG 2000"                        \
              "-IFD0:ImageWidth>XMP-tiff:ImageWidth"                   \
              "-IFD0:ImageHeight>XMP-tiff:ImageHeight"                 \
              "-IFD0:BitsPerSample>XMP-tiff:BitsPerSample"             \
  "-IFD0:PhotometricInterpretation>XMP-tiff:PhotometricInterpretation" \
              "-IFD0:Orientation>XMP-tiff:Orientation"                 \
              "-IFD0:SamplesPerPixel>XMP-tiff:SamplesPerPixel"         \
              "-IFD0:XResolution>XMP-tiff:XResolution"                 \
              "-IFD0:YResolution>XMP-tiff:YResolution"                 \
              "-IFD0:ResolutionUnit>XMP-tiff:ResolutionUnit"           \
              "-IFD0:Artist>XMP-tiff:Artist"                           \
              "-IFD0:Make>XMP-tiff:Make"                               \
              "-IFD0:Model>XMP-tiff:Model"                             \
              "-IFD0:Software>XMP-tiff:Software"                       \
              "${datetime}"                                            \
              -overwrite_original "$new_image" > /dev/null; then

            # If our image had an alpha channel, it'll be gone now, and
            # the XMP data needs to reflect that (previously, we were
            # taking that info from the original image).
            if $alpha_channel; then
              $EXIFTOOL -tagsFromFile "$sparse"                        \
                "-IFD0:BitsPerSample>XMP-tiff:BitsPerSample"           \
                "-IFD0:SamplesPerPixel>XMP-tiff:SamplesPerPixel"       \
  "-IFD0:PhotometricInterpretation>XMP-tiff:PhotometricInterpretation" \
                -overwrite_original "$new_image" > /dev/null
            fi

            rm "$sparse"

            # We successfully grabbed the metadata, so we can copy over
            # the new JP2 from ram.
            if cp "$new_image" "$final_image"; then
              # The copy worked, so we can remove the original TIFF.
              rm "$original_tiff"

            else
              echobad "Failed to copy JP2 to disc."
              mv "$original_tiff" "$badfile"
            fi

          else
            echobad "Failed to copy metadata."
            mv "$original_tiff" "$badfile"
          fi
        else
          echobad "Failed to convert to JPEG 2000."
          mv "$original_tiff" "$badfile"
          rm "$metafile" "$sparse"
        fi
      else
        echobad "Failed to extract XMP-less TIFF."
        mv "$original_tiff" "$badfile"
        rm "$metafile" "$sparse"
      fi

      rm -rf "$ramdir"
    else
      echogood "Ignoring contone $original_tiff"
      rm "$metafile"
    fi

  elif grep -q 'Bits/Sample: 1' ${metafile}; then
    if [ -z "$PROCESS_BITONALS" ]; then
      # It's bitonal, so we G4 compress it.
      echogood "Compressing $original_tiff with Group4 ..."

      problem=""
      #compressed="${name}-compressed.tif"
      compressed="$(mktemp "${RAM_PREFIX}-compressed.tif")"
      rm "$compressed"

      # Try to compress the image. This is the only part of this step
      # that should take any time. It should take a second or so.
      #if $IMAGEMAGICK "$original_tiff" -compress Group4 "$compressed"
      #then
      if tifftopnm "$original_tiff" | pnmtotiff -g4 -rowsperstrip \
          196136698 > "$compressed" 2> /dev/null; then
        # If it works, we can move the original out of the way.
        mv "$original_tiff" "$badfile"

        if $EXIFTOOL -tagsFromFile "$badfile" \
            "-IFD0:DocumentName"              \
            "-IFD0:ImageDescription="         \
            "-IFD0:Orientation"               \
            "-IFD0:XResolution"               \
            "-IFD0:YResolution"               \
            "-IFD0:ResolutionUnit"            \
            "-IFD0:ModifyDate"                \
            "-IFD0:Artist"                    \
            "-IFD0:Make"                      \
            "-IFD0:Model"                     \
            "-IFD0:Software"                  \
            -overwrite_original "$compressed" > /dev/null; then
          # Copy just the first page of the compressed TIFF into the place
          # of the original image.
          if $TIFFCP "${compressed},0" "$original_tiff"; then
            # If the copy worked, we can get rid of the temporary
            # compressed TIFF.
            rm "$compressed"

            # Assert that we have a datetime.
            if ! grep -q '^\s*DateTime:' ${metafile}; then
              datetime=$(date "+${DATE_TIF}")
              if ! $TIFFSET -s 306 "$datetime" "$original_tiff"; then
                echobad "Could not set date."
                problem="problem"
              fi
            fi

            # Set the document name.
            if ! $TIFFSET -s 269 "$original_tiff" "$original_tiff"; then
              echobad "Could not set document name."
              problem="problem"
            fi

            # Get the original software (which will have been overridden
            # by ImageMagick).
            software=$(awk '/^[ \t]*Software:/' "$metafile" \
                | sed -e 's/^\s*Software:\s*//')

            # Assert that there was software.
            if [ -z "$software" ]; then
              # Software is actually optional, so we just give a warning.
              echowarn "Could not extract software."

              # We also remove ImageMagick from the new image's software.
              # It automatically adds itself, and we hate that.
              if ! $EXIFTOOL -IFD0:Software= -overwrite_original \
                  "$original_tiff" > /dev/null; then
                echobad "Could not remove ImageMagick software."
                problem="problem"
              fi
            else
              # Set the software.
              if ! $TIFFSET -s 305 "$software" "$original_tiff"; then
                echobad "Could not set software."
                problem="problem"
              fi
            fi
          else
            echobad "Could not set metadata with exiftool."
            problem="problem"
          fi

          rm "$metafile"

          if [ -z "$problem" ]; then
            # Only delete the original if there were no problems.
            rm "$badfile"
          fi

        else
          echobad "Could not copy first page of TIFF."
          rm "$metafile" "$compressed"
        fi
      else
        echobad "Could not compress TIFF."
        mv "$original_tiff" "$badfile"
        rm "$metafile"
      fi
    else
      echogood "Ignoring bitonal $original_tiff"
      rm "$metafile"
    fi

  else
    echobad "Invalid source TIFF: $original_tiff"
    mv "$original_tiff" "$badfile"
    rm "$metafile"
  fi
done

echogood "Finished processing images."
