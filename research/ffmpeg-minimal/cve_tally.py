#!/usr/bin/env python3
"""cve_tally.py: counts FFmpeg's CVEs by the component they name, for TextMouth's research.

Research only (research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md); nothing in the
app runs it.

Usage:
    python3 -I -B research/ffmpeg-minimal/cve_tally.py fetch --work WORK
    python3 -I -B research/ffmpeg-minimal/cve_tally.py tally --work WORK [--since 2016]

fetch downloads every CVE whose description names FFmpeg from the National
Vulnerability Database (NVD's API 2.0, no key, one request per six seconds as
its rules ask) into WORK/nvd-ffmpeg.json. tally sorts them by the components
of build.py's sets, read from each description's words and file names
("libavcodec/wmaprodec.c", "the ASF demuxer"), and prints the counts by
component and by year, and each CVE of the WMA-only set in full.

A CVE can name more than one component, and one that names none of these is
counted as "elsewhere" (video codecs, filters, programs, protocols). The
words are matched in NVD's descriptions only; no FFmpeg code is read.
"""
import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True

# NVD's API, and the words it is asked for.
NVD_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=FFmpeg&resultsPerPage={size}&startIndex={start}"
PAGE_SIZE = 2000

# The components of build.py's sets, each with the words and file names that
# name it in a CVE's description, matched without regard to case.
COMPONENTS = {
    "WMA decoders": r"\bwma|wmav[12]|wmapro|wmalossless|wmavoice|windows media audio",
    "ASF demuxer": r"\basf\b|asfdec|asf_read|advanced systems format",
    "Matroska and WebM demuxer": r"matroska|\bmkv\b|webm",
    "Flash video demuxer": r"\bflv|flvdec|flash video",
    "AVI demuxer": r"\bavi\b|avidec",
    "RealMedia demuxer": r"rmdec|realmedia|\brm demuxer|ff_rm_",
    "RealAudio decoders (Cook, ACELP.net, ATRAC3, RALF, 14.4, 28.8)": r"\bcook|cookdec|\bsipr|atrac3(?!p)|\bralf|ra144|ra288|ra_144|ra_288|realaudio",
    "Musepack": r"musepack|mpc7|mpc8|mpcdec|\bmpc\b",
    "Ogg demuxer": r"\bogg|oggdec|oggparse",
    "Speex decoder": r"speex",
    "Opus decoder": r"\bopus",
    "Vorbis decoder": r"vorbis",
    "AAC decoder": r"\baac|aacdec|aacsbr|aacps",
    "MP3 and MP2 decoders": r"mpegaudio|\bmp3|\bmp2\b|mpadec",
    "AC-3 and E-AC-3 decoders": r"\bac3|eac3|\bac-3|e-ac-3",
    "DTS decoder": r"\bdca|\bdts\b|dcadec",
    "FLAC decoder": r"\bflac",
    "ALAC decoder": r"\balac",
    "TrueHD and MLP decoders": r"truehd|\bmlp",
    "TTA decoder": r"\btta\b|ttadec",
    "WavPack decoder": r"wavpack",
    "Monkey's Audio decoder": r"\bape\b|apedec|monkey",
    "ADPCM decoders": r"adpcm",
    "Nellymoser decoder": r"nellymoser",
    "GSM decoder": r"\bgsm",
    "PCM decoders": r"\bpcm\.c|\bpcm decoder|libavcodec/pcm",
}

# The components of the WMA-only set (b), listed CVE by CVE.
WMA_SET = ("WMA decoders", "ASF demuxer")

# The automatic match above also catches a CVE whose description only names
# the container its attack file came in ("a crafted AVI file" holding a video
# codec's bug), and FFmpeg's encoders and muxers, which no set compiles. So
# every match since 2016 was read by hand on November 16, 2026, and these are
# the CVEs whose bug lies in code a set compiles, by the component it lies in.
# A CVE left out was judged to lie elsewhere; two unclear ones are noted on
# the research page and not counted.
REVIEWED = {
    "CVE-2016-7122": "AVI demuxer", "CVE-2016-7555": "AVI demuxer", "CVE-2016-7785": "AVI demuxer",
    "CVE-2016-7905": "AVI demuxer", "CVE-2024-36618": "AVI demuxer",
    "CVE-2017-14057": "ASF demuxer", "CVE-2017-14223": "ASF demuxer", "CVE-2018-1999015": "ASF demuxer",
    "CVE-2016-9561": "AAC decoder", "CVE-2020-24995": "AAC decoder",
    "CVE-2017-11399": "Monkey's Audio decoder", "CVE-2026-125104": "Monkey's Audio decoder",
    "CVE-2026-125182": "Cook decoder", "CVE-2026-125203": "Cook decoder",
    "CVE-2016-8595": "GSM parser", "CVE-2018-13303": "AC-3 parser", "CVE-2018-1999013": "RealMedia demuxer",
    "CVE-2014-125008": "Ogg demuxer (Vorbis headers)", "CVE-2024-35369": "Speex decoder",
    "CVE-2026-125171": "Musepack SV7 decoder", "CVE-2026-125221": "FLAC parser", "CVE-2026-125224": "Vorbis parser",
}

# Which reviewed components each set compiles: a is all of them; c leaves out
# the AVI demuxer and the GSM parser; b is the ASF demuxer alone (no WMA
# decoder has one); d is the ASF demuxer and the Vorbis parser.
SET_COMPONENTS = {
    "a": set(REVIEWED.values()),
    "c": set(REVIEWED.values()) - {"AVI demuxer", "GSM parser"},
    "b": {"ASF demuxer"},
    "d": {"ASF demuxer", "Vorbis parser"},
}

# The components only the video containers bring (in set a, not in set c).
VIDEO_ONLY = ("Flash video demuxer", "AVI demuxer", "ADPCM decoders", "Nellymoser decoder", "GSM decoder")


def fetch(work):
    """Downloads every CVE NVD's keyword search for FFmpeg returns into
    WORK/nvd-ffmpeg.json, a page at a time."""
    vulnerabilities, start, total = [], 0, None
    while total is None or start < total:
        request = urllib.request.Request(NVD_URL.format(size=PAGE_SIZE, start=start),
                                         headers={"User-Agent": "research-script"})
        with urllib.request.urlopen(request, timeout=120) as response:
            page = json.load(response)
        total = page["totalResults"]
        vulnerabilities += page["vulnerabilities"]
        start += PAGE_SIZE
        if start < total:
            # NVD asks for at most five requests in thirty seconds without a key.
            time.sleep(6)
    record = {"fetched": time.strftime("%Y-%m-%d %H:%M %Z"), "total": total, "vulnerabilities": vulnerabilities}
    (Path(work) / "nvd-ffmpeg.json").write_text(json.dumps(record), encoding="utf-8")
    print(f"fetched {len(vulnerabilities)} of {total} CVEs")


def english_description(cve):
    """The CVE's English description, or ''."""
    for description in cve.get("descriptions", []):
        if description.get("lang") == "en":
            return description.get("value", "")
    return ""


def severity(cve):
    """The CVE's CVSS 3 base severity (from NVD or the CNA), or 'none given'."""
    metrics = cve.get("metrics", {})
    for key in ("cvssMetricV31", "cvssMetricV30"):
        for metric in metrics.get(key, []):
            return metric["cvssData"]["baseSeverity"]
    return "none given"


def tally(work, since):
    """Prints the CVEs by component, by year from `since`, and the WMA set's in full."""
    record = json.loads((Path(work) / "nvd-ffmpeg.json").read_text(encoding="utf-8"))
    patterns = {name: re.compile(pattern, re.IGNORECASE) for name, pattern in COMPONENTS.items()}
    by_component, elsewhere, total, wma_set, years = {}, 0, 0, [], {}
    for item in record["vulnerabilities"]:
        cve = item["cve"]
        year = int(cve["published"][:4])
        if year < since:
            continue
        total += 1
        text = english_description(cve)
        named = [name for name, pattern in patterns.items() if pattern.search(text)]
        if not named:
            elsewhere += 1
        for name in named:
            by_component.setdefault(name, []).append(cve["id"])
            years.setdefault(name, {}).setdefault(year, 0)
            years[name][year] += 1
        if any(name in WMA_SET for name in named):
            wma_set.append((cve["id"], cve["published"][:10], severity(cve), text))
    print(f"NVD, fetched {record['fetched']}: {record['total']} CVEs name FFmpeg; {total} published since {since}.")
    print(f"Naming no component of the sets (video, filters, programs, protocols, ...): {elsewhere}.")
    in_parity = {cve for name, cves in by_component.items() for cve in cves}
    in_wma = {cve for name in WMA_SET for cve in by_component.get(name, [])}
    in_audio_set = {cve for name, cves in by_component.items() if name not in VIDEO_ONLY for cve in cves}
    print(f"Naming a component of set a (parity): {len(in_parity)}; of set c (no video containers): {len(in_audio_set)}; of set b (WMA only): {len(in_wma)}.")
    print("By component (CVEs since {}; by year):".format(since))
    for name in COMPONENTS:
        cves = by_component.get(name, [])
        per_year = ", ".join(f"{year}: {count}" for year, count in sorted(years.get(name, {}).items()))
        print(f"  {name}: {len(cves)}" + (f" ({per_year})" if per_year else ""))
    print("The WMA-only set's automatic matches:")
    for cve_id, published, level, text in sorted(wma_set):
        print(f"  {cve_id} ({published}, {level}): {text}")
    reviewed(record)


def reviewed(record):
    """Prints the CVEs read by hand (REVIEWED): each with its date, severity,
    and component, then how many each set compiles, and by year."""
    by_id = {item["cve"]["id"]: item["cve"] for item in record["vulnerabilities"]}
    print("Read by hand, the bug in code a set compiles:")
    years = {}
    for cve_id, component in sorted(REVIEWED.items(), key=lambda item: by_id[item[0]]["published"]):
        cve = by_id[cve_id]
        year = int(cve["published"][:4])
        years[year] = years.get(year, 0) + 1
        print(f"  {cve_id} ({cve['published'][:10]}, {severity(cve)}): {component}")
    print("  by year published: " + ", ".join(f"{year}: {count}" for year, count in sorted(years.items())))
    for set_name, components in SET_COMPONENTS.items():
        count = sum(1 for component in REVIEWED.values() if component in components)
        print(f"  set {set_name}: {count}")


def main():
    """Reads the command line and runs one step."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", choices=["fetch", "tally"])
    parser.add_argument("--work", required=True, help="the scratch folder")
    parser.add_argument("--since", type=int, default=2016, help="the first year counted")
    options = parser.parse_args()
    Path(options.work).mkdir(parents=True, exist_ok=True)
    if options.step == "fetch":
        fetch(options.work)
    else:
        tally(options.work, options.since)
    return 0


if __name__ == "__main__":
    sys.exit(main())
