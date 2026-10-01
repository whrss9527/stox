#!/usr/bin/env python3
"""把 docs/app-store/listing 里的 App Store 资料填进 App Store Connect，选上构建，需要时提交审核。

只用 Python 自带的库；JWT 用 openssl 命令签名（Ubuntu 的 OpenSSL、macOS 的 LibreSSL 都行）。

  scripts/app-store-connect.py check [--version 0.49.0] [--screenshots 目录]
      不联网，只检查资料文件：该有的文件都在、没超过字数、网址是 https、截图的格式和尺寸对。
      给了 --version 时也检查这个版本的“此版本的新增内容”。

  scripts/app-store-connect.py sync --version 0.49.0
        [--build 612.3 --wait-build-minutes 60 | --attach-latest-build] [--submit] [--screenshots 目录] [--dry-run]
      先 check，再读出 App Store Connect 上现在的样子，只改和仓库里不一样的地方（重复运行不会重复改）：
      内容版权、价格（免费）、销售范围、版本号、类别、名称和副标题、年龄分级、描述和关键词、截图、
      审核信息，选上构建；给了 --submit 时提交审核。--dry-run 只读不写，把要写的内容打印出来。

截图不用 --screenshots 指定时用 docs/app-store/listing/screenshots/<主要语言>（有的话），都没有就不动截图。

sync 要的环境变量：
  ASC_KEY_ID、ASC_ISSUER_ID   App Store Connect API 密钥的 Key ID 和 Issuer ID
  ASC_KEY_P8                  密钥文件 AuthKey_XXXX.p8 的内容（原文或 base64）；
                              不设时读 ~/.appstoreconnect/private_keys/AuthKey_<Key ID>.p8
  APPSTORE_REVIEW_CONTACT     可选，审核联系人，四行：名、姓、带国家码的电话、邮箱；不设时不改网页上填的

只能在网页上做的事（新建 App、App 隐私、欧盟 DSA 商家身份、协议）见 docs/app-store.md。
"""
import argparse
import base64
import binascii
import datetime
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LISTING = ROOT / "docs" / "app-store" / "listing"
CHANGELOG = ROOT / "CHANGELOG.md"
API_BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "io.github.whrss9527.stox"
PLATFORM = "MAC_OS"
SCREENSHOT_TYPE = "APP_DESKTOP"
# CHANGELOG.md 只有中文：这个语言没写 whats_new 文件时，用 CHANGELOG 里这个版本的一节。
CHANGELOG_LOCALE = "zh-Hans"

# 每种语言一个文件夹，里面的文件 → (App Store Connect 里的字段, 字数上限, 能不能空着)。
LOCALE_FILES = {
    "name.txt": ("name", 30, False),
    "subtitle.txt": ("subtitle", 30, True),
    "promotional_text.txt": ("promotionalText", 170, True),
    "description.txt": ("description", 4000, False),
    "keywords.txt": ("keywords", 100, False),
    "support_url.txt": ("supportUrl", None, False),
    "marketing_url.txt": ("marketingUrl", None, True),
    "privacy_url.txt": ("privacyPolicyUrl", None, False),
}
URL_FIELDS = ("supportUrl", "marketingUrl", "privacyPolicyUrl")
# App 信息（appInfoLocalizations）里的字段，其余的在版本（appStoreVersionLocalizations）里。
APP_INFO_FIELDS = ("name", "subtitle", "privacyPolicyUrl")
VERSION_FIELDS = ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl")
FIELD_NAMES = {
    "name": "名称", "subtitle": "副标题", "promotionalText": "推广文本", "description": "描述",
    "keywords": "关键词", "supportUrl": "支持网址", "marketingUrl": "营销网址", "privacyPolicyUrl": "隐私政策网址",
    "whatsNew": "此版本的新增内容",
}
WHATS_NEW_LIMIT = 4000
REVIEW_NOTES_LIMIT = 4000
SCREENSHOT_SIZES = ((1280, 800), (1440, 900), (2560, 1600), (2880, 1800))
SCREENSHOT_SUFFIXES = (".png", ".jpg", ".jpeg")
LOCALE_DIR = re.compile(r"^[a-z]{2,3}(-[A-Za-z]{2,4})?$")
VERSION_STRING = re.compile(r"^\d+(\.\d+){0,2}$")

# 年龄分级问卷（AgeRatingDeclaration；2025 年苹果加了一批新问题）：程度类的问题都答“无”，是非题都答“否”。
# 只改 GET 返回里有的键，苹果去掉的问题不会再发；返回里有、这里不认识的键会提醒去网页上看一眼。
AGE_RATING_LEVELS = (
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
    "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
)
AGE_RATING_FLAGS = (
    "advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
    "parentalControls", "socialMedia", "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent",
)
# 不是问卷的答案，不动：儿童类别、手动指定的分级、韩国的分级、说明网址。
AGE_RATING_UNTOUCHED = (
    "kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
    "gracRatingClassificationNumber", "developerAgeRatingInfoUrl",
)

# 版本的状态（appVersionState，旧的 appStoreState 也认）。
# 还能改的：准备提交、被拒、开发者撤回，以及 READY_FOR_REVIEW（加进了审核提交、还没点提交）。
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW",
}
# 在审核或者审核通过、等着上架：这时既不能改它，也不能新建版本。
BUSY_STATES = {
    "WAITING_FOR_REVIEW", "IN_REVIEW", "WAITING_FOR_EXPORT_COMPLIANCE", "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "ACCEPTED", "PENDING_CONTRACT",
}
# 其中还没审完、可以撤回的（--withdraw-review）：撤回后版本变回 DEVELOPER_REJECTED，可以改、可以换构建再提交。
WITHDRAWABLE_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}

SUBMIT_HINT = (
    "提交审核没成功，苹果的原因见上面。常见的是只能在网页上做的事还没做：App 隐私（App Privacy）问卷、"
    "欧盟《数字服务法》商家身份、协议（见 docs/app-store.md）。在 App Store Connect 网页上处理好以后，"
    "再运行一次 app-store 工作流（build 选 none，勾上 listing 和 submit）。"
)


class Failure(Exception):
    """要停下来的错误，消息是写给人看的中文。"""


# ---------------------------------------------------------------- 输出


def _escape(text, prop=False):
    text = str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    if prop:
        text = text.replace(":", "%3A").replace(",", "%2C")
    return text


def annotate(kind, message, title=None):
    """GitHub Actions 的注释（::error:: / ::warning:: / ::notice::），在本机运行时就是普通的一行。"""
    head = f"::{kind}" + (f" title={_escape(title, True)}" if title else "")
    print(f"{head}::{_escape(message)}", flush=True)


def describe(attributes):
    """打印要写的字段：短的写出值，长的写字数；审核联系人的信息不打到日志里。"""
    parts = []
    for key, value in attributes.items():
        if key.startswith("contact"):
            parts.append(key)
        elif isinstance(value, str) and (len(value) > 60 or "\n" in value):
            parts.append(f"{key}（{len(value)} 字）")
        else:
            parts.append(f"{key}={json.dumps(value, ensure_ascii=False)}")
    return "，".join(parts)


# ---------------------------------------------------------------- 资料文件


def read_text(path):
    return Path(path).read_text(encoding="utf-8").replace("\r\n", "\n").strip()


def changelog_section(text, version):
    """CHANGELOG.md 里 “## 版本号” 这一节的内容（和 scripts/release-notes.sh 取法一样），没有时是空字符串。"""
    heading, lines, found = f"## {version}", [], False
    for line in text.splitlines():
        if not found:
            found = line == heading
            continue
        if line.startswith("## "):
            break
        lines.append(line)
    return "\n".join(lines).strip()


def plain_text(markdown, limit=WHATS_NEW_LIMIT):
    """App Store 只认纯文本：列表的 “- ” 换成 “• ”，去掉标题的 #、代码的反引号和链接的网址。"""
    lines = []
    for line in markdown.splitlines():
        line = line.rstrip()
        line = re.sub(r"^(\s*)[-*+] ", r"\1• ", line)
        line = re.sub(r"^#+\s*", "", line)
        line = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)
        lines.append(line.replace("`", ""))
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


SOF_MARKERS = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def image_info(path):
    """读 PNG 的 IHDR 或 JPEG 的 SOF：返回 (格式, 宽, 高, 有没有透明)；不是 PNG/JPEG 时返回 None。"""
    data = Path(path).read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        if len(data) < 33 or data[12:16] != b"IHDR":
            return None
        width, height = struct.unpack(">II", data[16:24])
        # 颜色类型 4、6 带 alpha 通道；其他类型带 tRNS 块时也有透明色。
        alpha = data[25] in (4, 6)
        pos = 8
        while pos + 8 <= len(data):
            length, kind = struct.unpack(">I4s", data[pos:pos + 8])
            if kind == b"tRNS":
                alpha = True
            if kind in (b"IDAT", b"IEND"):
                break
            pos += 12 + length
        return "PNG", width, height, alpha
    if data.startswith(b"\xff\xd8"):
        pos = 2
        while pos + 4 <= len(data):
            if data[pos] != 0xFF:
                return None
            marker = data[pos + 1]
            if marker == 0xFF:  # 填充字节
                pos += 1
                continue
            if marker == 0x01 or 0xD0 <= marker <= 0xD9:  # 没有长度的标记
                pos += 2
                continue
            length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
            if marker in SOF_MARKERS:
                if pos + 9 > len(data):
                    return None
                height, width = struct.unpack(">HH", data[pos + 5:pos + 9])
                return "JPEG", width, height, False
            pos += 2 + length
    return None


def is_https(url):
    parts = urllib.parse.urlsplit(url)
    return parts.scheme == "https" and bool(parts.netloc) and " " not in url


class Listing:
    """docs/app-store/listing 里的全部资料。load() 把问题记进 errors（不能用）和 warnings（提醒一下）。"""

    def __init__(self, root=LISTING, changelog=CHANGELOG, today=None):
        self.root = Path(root)
        self.changelog = Path(changelog)
        self.today = today or datetime.date.today()
        self.errors, self.warnings = [], []
        self.config = {}
        self.locales = {}  # 语言 → {字段: 文字}
        self.review_notes = ""
        self.whats_new = {}  # 语言 → (文字, 出处)，没有时是 (None, None)
        self.screenshots = []
        self.copyright = ""

    def rel(self, path):
        try:
            return str(Path(path).resolve().relative_to(ROOT))
        except ValueError:
            return str(path)

    @property
    def primary_locale(self):
        return self.config.get("primaryLocale", "")

    def load(self, version=None, screenshots=None):
        self.load_config()
        self.load_locales()
        self.load_review_notes()
        if version is not None:
            if VERSION_STRING.match(version):
                self.load_whats_new(version)
            else:
                self.errors.append(f"版本号 {version} 不对，应该像 0.49.0 这样")
        self.load_screenshots(screenshots)
        return self

    def load_config(self):
        path = self.root / "config.json"
        try:
            self.config = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self.errors.append(f"没有 {self.rel(path)}")
            return
        except json.JSONDecodeError as err:
            self.errors.append(f"{self.rel(path)} 不是合法的 JSON：{err}")
            return
        if not isinstance(self.config, dict):
            self.errors.append(f"{self.rel(path)} 要是一个 JSON 对象")
            self.config = {}
            return
        expected = {
            "primaryLocale": str, "primaryCategory": str, "secondaryCategory": str, "contentRightsDeclaration": str,
            "copyright": str, "releaseType": str, "excludedTerritories": list, "availableInNewTerritories": bool,
            "price": str, "ageRating": str,
        }
        for key, kind in expected.items():
            if not isinstance(self.config.get(key), kind):
                self.errors.append(f"{self.rel(path)} 里的 {key} 缺了或者类型不对（应该是 {kind.__name__}）")
        config = self.config
        choices = {
            "contentRightsDeclaration": ("DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"),
            # SCHEDULED 还要一个日期，这里不支持。
            "releaseType": ("MANUAL", "AFTER_APPROVAL"),
            "price": ("free",),
            "ageRating": ("none",),
        }
        for key, allowed in choices.items():
            if isinstance(config.get(key), str) and config[key] not in allowed:
                self.errors.append(f"{self.rel(path)} 里的 {key} 只能是 {' / '.join(allowed)}，现在是 {config[key]}")
        for key in ("primaryCategory", "secondaryCategory"):
            value = config.get(key)
            if isinstance(value, str) and value and not re.match(r"^[A-Z_]+$", value):
                self.errors.append(f"{self.rel(path)} 里的 {key} 要写 App Store Connect 的类别 ID，比如 FINANCE")
        if not config.get("primaryCategory"):
            self.errors.append(f"{self.rel(path)} 里没有 primaryCategory")
        for territory in config.get("excludedTerritories") or []:
            if not isinstance(territory, str) or not re.match(r"^[A-Z]{3}$", territory):
                self.errors.append(f"{self.rel(path)} 里的 excludedTerritories 要写三个大写字母的地区代码，比如 CHN，现在有 {territory!r}")
        if isinstance(config.get("copyright"), str):
            self.copyright = config["copyright"].replace("{year}", str(self.today.year))

    def load_locales(self):
        if not self.root.is_dir():
            self.errors.append(f"没有 {self.rel(self.root)} 文件夹")
            return
        for folder in sorted(p for p in self.root.iterdir() if p.is_dir() and p.name != "screenshots"):
            if not LOCALE_DIR.match(folder.name):
                self.errors.append(f"{self.rel(folder)}：文件夹名要是 App Store Connect 的语言代码，比如 en-US、zh-Hans")
                continue
            fields = {}
            for filename, (field, limit, optional) in LOCALE_FILES.items():
                path = folder / filename
                if not path.is_file():
                    self.errors.append(f"缺少 {self.rel(path)}（{FIELD_NAMES[field]}）")
                    continue
                text = read_text(path)
                fields[field] = text
                if not text:
                    if not optional:
                        self.errors.append(f"{self.rel(path)} 是空的（{FIELD_NAMES[field]}不能空着）")
                    continue
                if limit and len(text) > limit:
                    self.errors.append(f"{self.rel(path)} 有 {len(text)} 个字，{FIELD_NAMES[field]}最多 {limit} 个")
                if field in URL_FIELDS and not is_https(text):
                    self.errors.append(f"{self.rel(path)} 要写一个 https:// 开头的网址，现在是 {text!r}")
            keywords = fields.get("keywords", "")
            if "，" in keywords or "、" in keywords:
                self.errors.append(f"{self.rel(folder / 'keywords.txt')}：关键词之间用英文逗号分开，不要用中文逗号或顿号")
            if keywords and any(not item.strip() for item in keywords.split(",")):
                self.errors.append(f"{self.rel(folder / 'keywords.txt')}：有空的关键词（两个逗号挨着，或者开头结尾有逗号）")
            if "\n" in fields.get("name", "") + fields.get("subtitle", "") + keywords:
                self.errors.append(f"{self.rel(folder)}：名称、副标题和关键词只能写一行")
            self.locales[folder.name] = fields
        if self.primary_locale and self.primary_locale not in self.locales:
            self.errors.append(f"没有主要语言 {self.primary_locale} 的文件夹 {self.rel(self.root / self.primary_locale)}")

    def load_review_notes(self):
        path = self.root / "review_notes.txt"
        if not path.is_file():
            self.errors.append(f"缺少 {self.rel(path)}（给审核员的备注）")
            return
        self.review_notes = read_text(path)
        if not self.review_notes:
            self.errors.append(f"{self.rel(path)} 是空的")
        elif len(self.review_notes) > REVIEW_NOTES_LIMIT:
            self.errors.append(f"{self.rel(path)} 有 {len(self.review_notes)} 个字，审核备注最多 {REVIEW_NOTES_LIMIT} 个")

    def load_whats_new(self, version):
        """每种语言的 whats_new/<版本>.txt；简体中文没写时用 CHANGELOG.md 里这一节。都没有时记成 None。"""
        for locale in self.locales:
            path = self.root / locale / "whats_new" / f"{version}.txt"
            text, source = None, None
            if path.is_file():
                text, source = read_text(path), self.rel(path)
                if not text:
                    self.errors.append(f"{self.rel(path)} 是空的")
                    text = None
                elif len(text) > WHATS_NEW_LIMIT:
                    self.errors.append(f"{self.rel(path)} 有 {len(text)} 个字，此版本的新增内容最多 {WHATS_NEW_LIMIT} 个")
            elif locale == CHANGELOG_LOCALE and self.changelog.is_file():
                section = changelog_section(self.changelog.read_text(encoding="utf-8"), version)
                if section:
                    text, source = plain_text(section), f"{self.rel(self.changelog)} 的 ## {version}"
            if text is None:
                hint = f"加上 {self.rel(path)}"
                if locale == CHANGELOG_LOCALE:
                    hint += f"，或者在 CHANGELOG.md 里写上 ## {version} 这一节"
                self.warnings.append(f"{locale} 没有 {version} 的“此版本的新增内容”：App Store 上的第一个版本不用写，以后的版本要{hint}")
            self.whats_new[locale] = (text, source)

    def load_screenshots(self, folder):
        explicit = folder is not None
        if not explicit:
            folder = self.root / "screenshots" / self.primary_locale
            if not self.primary_locale or not folder.is_dir():
                return
        folder = Path(folder)
        if not folder.is_dir():
            self.errors.append(f"截图文件夹 {folder} 不存在")
            return
        files = sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in SCREENSHOT_SUFFIXES)
        if not files:
            if explicit:
                self.errors.append(f"截图文件夹 {self.rel(folder)} 里没有 PNG 或 JPEG")
            return
        if len(files) > 10:
            self.errors.append(f"{self.rel(folder)} 里有 {len(files)} 张截图，最多 10 张")
        sizes = set()
        for path in files:
            info = image_info(path)
            if info is None:
                self.errors.append(f"{self.rel(path)} 不是 PNG 或 JPEG")
                continue
            kind, width, height, alpha = info
            sizes.add((width, height))
            if (width, height) not in SCREENSHOT_SIZES:
                allowed = "、".join(f"{w}×{h}" for w, h in SCREENSHOT_SIZES)
                self.errors.append(f"{self.rel(path)} 是 {width}×{height}，Mac 的截图只能是 {allowed}")
            if alpha:
                self.warnings.append(f"{self.rel(path)} 带透明通道，App Store 可能不收；存成不带 alpha 的 PNG 或者 JPEG")
        if len(sizes) > 1:
            self.warnings.append(f"{self.rel(folder)} 里的截图尺寸不一样，最好都用同一个尺寸")
        self.screenshots = files


def run_check(version=None, screenshots=None, root=LISTING, changelog=CHANGELOG):
    """检查资料文件并打印结果；有错误时抛出 Failure。"""
    listing = Listing(root, changelog).load(version, screenshots)
    print(f"==> 检查 {listing.rel(listing.root)}")
    for locale, fields in listing.locales.items():
        counts = []
        for _, (field, limit, _) in LOCALE_FILES.items():
            if limit and field in fields:
                counts.append(f"{FIELD_NAMES[field]} {len(fields[field])}/{limit}")
        print(f"    {locale}：{'，'.join(counts)}")
        text, source = listing.whats_new.get(locale, (None, None))
        if text:
            print(f"    {locale}：此版本的新增内容 {len(text)}/{WHATS_NEW_LIMIT}（{source}）")
    print(f"    审核备注 {len(listing.review_notes)}/{REVIEW_NOTES_LIMIT}")
    if listing.screenshots:
        print(f"    截图 {len(listing.screenshots)} 张：{'、'.join(p.name for p in listing.screenshots)}")
    else:
        print("    没有截图（不动 App Store Connect 上的截图）")
    for message in listing.warnings:
        annotate("warning", message)
    for message in listing.errors:
        annotate("error", message)
    if listing.errors:
        raise Failure(f"App Store 资料有 {len(listing.errors)} 处问题，见上面")
    print("    没有问题")
    return listing


# ---------------------------------------------------------------- JWT


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(der, size=32):
    """openssl 签出来的 ECDSA 签名是 DER（SEQUENCE 里两个 INTEGER：r、s），JWT 要的是 r、s 各 32 字节直接拼起来。"""

    def length_at(pos):
        first = der[pos]
        if first < 0x80:
            return first, pos + 1
        count = first & 0x7F
        return int.from_bytes(der[pos + 1:pos + 1 + count], "big"), pos + 1 + count

    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("签名不是 DER 格式")
    _, pos = length_at(1)
    parts = []
    for _ in range(2):
        if der[pos] != 0x02:
            raise ValueError("签名不是 DER 格式")
        length, pos = length_at(pos + 1)
        # INTEGER 是有符号的：最高位是 1 时前面补了 0x00；数值小时又会少于 32 字节。
        value = der[pos:pos + length].lstrip(b"\x00")
        pos += length
        if len(value) > size:
            raise ValueError("签名里的整数太长")
        parts.append(value.rjust(size, b"\x00"))
    return b"".join(parts)


def make_jwt(key_id, issuer_id, key_path, now=None, lifetime=19 * 60, openssl="openssl"):
    """App Store Connect API 的令牌：ES256，最长 20 分钟有效。"""
    now = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload))
    try:
        result = subprocess.run(
            [openssl, "dgst", "-sha256", "-sign", str(key_path)], input=signing_input.encode(), capture_output=True
        )
    except FileNotFoundError:
        raise Failure("没有 openssl 命令，签不了 JWT") from None
    if result.returncode != 0:
        raise Failure(f"用 openssl 签名 JWT 失败（密钥不对？）：{result.stderr.decode(errors='replace').strip()}")
    try:
        signature = der_to_raw(result.stdout)
    except (ValueError, IndexError) as err:
        raise Failure(f"openssl 的签名读不懂：{err}") from None
    return signing_input + "." + b64url(signature)


class TokenSource:
    """等构建处理时脚本可能跑一个多小时，令牌用了 15 分钟就换一个新的。"""

    def __init__(self, key_id, issuer_id, key_path, clock=time.time):
        self.key_id, self.issuer_id, self.key_path, self.clock = key_id, issuer_id, key_path, clock
        self.token, self.issued = None, 0.0

    def __call__(self):
        now = self.clock()
        if self.token is None or now - self.issued > 15 * 60:
            self.token = make_jwt(self.key_id, self.issuer_id, self.key_path, now=now)
            self.issued = now
        return self.token


def load_key(env, workdir):
    """从环境变量读出 Key ID、Issuer ID 和私钥文件的位置（ASC_KEY_P8 写进 workdir 里只有自己能读的文件）。"""
    key_id = env.get("ASC_KEY_ID", "").strip()
    issuer_id = env.get("ASC_ISSUER_ID", "").strip()
    raw = env.get("ASC_KEY_P8", "")
    missing = [name for name, value in (("ASC_KEY_ID", key_id), ("ASC_ISSUER_ID", issuer_id)) if not value]
    path = None
    if raw.strip():
        pem = raw
        if "BEGIN PRIVATE KEY" not in raw:
            try:
                pem = base64.b64decode("".join(raw.split()), validate=True).decode("utf-8")
            except (binascii.Error, UnicodeDecodeError):
                pem = ""
        if "BEGIN PRIVATE KEY" not in pem:
            raise Failure("ASC_KEY_P8 不是 .p8 私钥（原文或 base64）")
        path = Path(workdir) / "AuthKey.p8"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(pem.strip() + "\n")
    elif key_id:
        path = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
        if not path.is_file():
            missing.append("ASC_KEY_P8")
    else:
        missing.append("ASC_KEY_P8")
    if missing:
        raise Failure(f"缺少 {'、'.join(missing)}：App Store Connect API 密钥，怎么准备见 docs/app-store.md 的“添加 Secrets”")
    return key_id, issuer_id, path


def parse_contact(text):
    """APPSTORE_REVIEW_CONTACT：四行，名、姓、带国家码的电话、邮箱。"""
    lines = [line.strip() for line in text.strip().splitlines() if line.strip()]
    if len(lines) != 4 or "@" not in lines[3]:
        raise Failure("APPSTORE_REVIEW_CONTACT 要写四行：名、姓、带国家码的电话（比如 +86 138 0000 0000）、邮箱")
    first, last, phone, email = lines
    return {"contactFirstName": first, "contactLastName": last, "contactPhone": phone, "contactEmail": email}


# ---------------------------------------------------------------- HTTP


class ApiError(Exception):
    """App Store Connect 返回的错误：errors 里每一项有 status、code、title、detail。"""

    def __init__(self, method, path, status, errors):
        super().__init__(f"{method} {path}: HTTP {status}")
        self.method, self.path, self.status, self.errors = method, path, status, errors

    def lines(self):
        out = []
        for item in self.errors or [{"status": str(self.status), "title": "（没有错误说明）"}]:
            text = f"{item.get('status', self.status)} {item.get('code', '')}：{item.get('title', '')}"
            if item.get("detail"):
                text += f" — {item['detail']}"
            out.append(text)
            # 提交审核时苹果把具体缺了什么放在 meta.associatedErrors 里。
            associated = (item.get("meta") or {}).get("associatedErrors") or {}
            for where, errors in associated.items():
                for sub in errors or []:
                    out.append(f"  {where}：{sub.get('code', '')} {sub.get('title', '')} {sub.get('detail', '')}".rstrip())
        return out

    def report(self, kind="error"):
        for line in self.lines():
            annotate(kind, f"{self.method} {self.path}：{line}", title="App Store Connect")


def urllib_send(method, url, headers, body):
    """发一个请求，返回 (状态码, 返回内容)。测试里换成假的。"""
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


DRY = "DRY-RUN"


class Api:
    """App Store Connect API。演练（dry_run）时 POST / PATCH / DELETE 只打印不发送，返回一个假的资源，
    之后读这个假资源下面的东西都当作空的。"""

    def __init__(self, token, send=urllib_send, dry_run=False, sleep=time.sleep, base=API_BASE):
        self.token, self.send, self.dry_run, self.sleep, self.base = token, send, dry_run, sleep, base
        self.dry_count = 0

    def url(self, path, params=None):
        url = path if path.startswith(("https://", "http://")) else self.base + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, safe="[],")
        return url

    def request(self, method, path, params=None, payload=None, allow_404=False):
        url = self.url(path, params)
        shown = urllib.parse.urlsplit(url).path
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        for attempt in range(4):
            headers = {"Authorization": "Bearer " + self.token(), "Accept": "application/json"}
            if body is not None:
                headers["Content-Type"] = "application/json"
            try:
                status, data = self.send(method, url, headers, body)
            except OSError as err:
                # 读的请求出了网络问题可以重试；写的请求可能已经生效，不重试。
                if method == "GET" and attempt < 3:
                    self.sleep(2 ** (attempt + 1))
                    continue
                raise Failure(f"连不上 App Store Connect（{method} {shown}）：{err}") from None
            # 429 是请求太多，苹果没有处理；5xx 只对读的请求重试。
            if (status == 429 or (status >= 500 and method == "GET")) and attempt < 3:
                self.sleep(2 ** (attempt + 1))
                continue
            break
        if status == 404 and allow_404:
            return None
        if status >= 400:
            try:
                errors = json.loads(data or b"{}").get("errors") or []
            except (ValueError, AttributeError):
                errors = []
            raise ApiError(method, shown, status, errors)
        if not data:
            return {}
        try:
            return json.loads(data)
        except ValueError:
            raise Failure(f"App Store Connect 返回的不是 JSON（{method} {shown}，HTTP {status}）") from None

    def get(self, path, params=None, allow_404=False):
        if self.dry_run and DRY in path:
            return None
        return self.request("GET", path, params, allow_404=allow_404)

    def pages(self, path, params=None, allow_404=False):
        """按 links.next 一页一页地读。"""
        if self.dry_run and DRY in path:
            return
        url, query = path, params
        while url:
            page = self.request("GET", url, query, allow_404=allow_404)
            if page is None:
                return
            yield page
            url, query = (page.get("links") or {}).get("next"), None
            if url and not url.startswith(self.base + "/"):
                raise Failure(f"App Store Connect 给的下一页地址不对：{url}")

    def get_all(self, path, params=None, allow_404=False):
        """所有页的 data 和 included 合在一起。"""
        data, included = [], []
        for page in self.pages(path, params, allow_404):
            items = page.get("data")
            data.extend(items if isinstance(items, list) else [items] if items else [])
            included.extend(page.get("included") or [])
        return data, included

    def write(self, method, path, payload=None, summary=""):
        label = f"{method} {path}" + (f"：{summary}" if summary else "")
        if self.dry_run:
            print(f"    （演练，没有写入）{label}", flush=True)
            self.dry_count += 1
            if method == "DELETE":
                return None
            data = (payload or {}).get("data")
            data = data if isinstance(data, dict) else {}
            return {"type": data.get("type"), "id": f"{DRY}-{self.dry_count}", "attributes": dict(data.get("attributes") or {})}
        print(f"    {label}", flush=True)
        response = self.request(method, path, payload=payload)
        return (response or {}).get("data")

    def upload(self, operation, chunk):
        """按预约返回的上传操作把一段文件传上去。这些地址自带签名，不用带令牌。"""
        headers = {item["name"]: item["value"] for item in operation.get("requestHeaders") or []}
        for attempt in range(4):
            try:
                status, _ = self.send(operation.get("method", "PUT"), operation["url"], headers, chunk)
            except OSError:
                status = 0
            if 200 <= status < 300:
                return
            if attempt < 3:
                self.sleep(2 ** (attempt + 1))
        raise Failure(f"上传截图失败（HTTP {status}）")


def rel_id(resource, name):
    """资源的某个关系指向的 ID（要在请求里 include 这个关系才有）。"""
    data = (((resource or {}).get("relationships") or {}).get(name) or {}).get("data")
    return data.get("id") if isinstance(data, dict) else None


def resource_state(resource):
    attributes = resource.get("attributes") or {}
    return attributes.get("appVersionState") or attributes.get("state") or attributes.get("appStoreState")


def same(current, wanted):
    if isinstance(wanted, str):
        return (current or "").replace("\r\n", "\n").strip() == wanted.strip()
    return current == wanted


def differences(current, wanted):
    return {key: value for key, value in wanted.items() if not same((current or {}).get(key), value)}


def is_zero(price):
    try:
        return float(price) == 0
    except (TypeError, ValueError):
        return False


def md5(path):
    return hashlib.md5(Path(path).read_bytes()).hexdigest()


def age_rating_answers(current):
    """要改的年龄分级答案：GET 返回里有的程度类问题改成 NONE，是非题改成 false，已经是了的不发。"""
    answers = {}
    for key in AGE_RATING_LEVELS:
        if key in current and current[key] != "NONE":
            answers[key] = "NONE"
    for key in AGE_RATING_FLAGS:
        if key in current and current[key] is not False:
            answers[key] = False
    return answers


# ---------------------------------------------------------------- 同步


class Sync:
    def __init__(self, api, listing, version, build=None, wait_minutes=0, attach_latest=False, submit=False,
                 contact=None, withdraw=False, sleep=time.sleep, clock=time.time):
        self.api, self.listing, self.version = api, listing, version
        self.build_number, self.wait_minutes, self.attach_latest = build, wait_minutes, attach_latest
        self.submit, self.contact, self.withdraw, self.sleep, self.clock = submit, contact, withdraw, sleep, clock
        self.config = listing.config
        self.changes = []
        self.app, self.app_id = None, None
        self.versions = []
        self.editable_version = None
        self.version_id = None
        self.first_version = False
        self.localization_ids = {}
        self.attached_build = None

    def step(self, title):
        print(f"==> {title}", flush=True)

    def changed(self, text):
        self.changes.append(text)

    def run(self):
        self.find_app()
        self.inspect_versions()
        self.app_attributes()
        self.price()
        self.availability()
        self.prepare_version()
        self.app_info()
        self.version_localizations()
        self.screenshots()
        self.review_detail()
        self.attach_build()
        if self.submit:
            self.submit_for_review()
        self.summary()

    def find_app(self):
        self.step(f"找 App（{BUNDLE_ID}）")
        apps, _ = self.api.get_all("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "limit": 200})
        app = next((a for a in apps if (a.get("attributes") or {}).get("bundleId") == BUNDLE_ID), None)
        if app is None:
            raise Failure(
                f"App Store Connect 里还没有 Bundle ID 为 {BUNDLE_ID} 的 App。先在网页上新建 App"
                "（docs/app-store.md 第 4 步），再运行。"
            )
        self.app, self.app_id = app, app["id"]
        attributes = app.get("attributes") or {}
        print(f"    {attributes.get('name')}（{self.app_id}）")
        primary = attributes.get("primaryLocale")
        if primary and primary != self.listing.primary_locale:
            annotate("warning", f"App 的主要语言是 {primary}，资料里写的是 {self.listing.primary_locale}；主要语言要在网页上的 App 信息里改")

    def inspect_versions(self):
        """先只读：有版本在审核时停下（--withdraw-review 时记下来，检查都过了再撤回）；
        不是第一个版本却没写“此版本的新增内容”时停下。都在写入任何东西之前。"""
        self.versions, _ = self.api.get_all(
            f"/v1/apps/{self.app_id}/appStoreVersions", {"filter[platform]": PLATFORM, "limit": 200}
        )
        to_withdraw = []
        for version in self.versions:
            state = resource_state(version)
            if state not in BUSY_STATES:
                continue
            if self.withdraw and state in WITHDRAWABLE_STATES:
                to_withdraw.append(version)
                continue
            hint = "等它有了结果后再运行。"
            if state in WITHDRAWABLE_STATES:
                hint = "等它有了结果后再运行；想用新版本替换它，运行时勾上 withdraw（先撤回审核）。"
            raise Failure(
                f"版本 {(version.get('attributes') or {}).get('versionString')} 正在审核或等待发布（{state}），现在不能改。" + hint
            )
        # 要撤回的版本撤回后可以改，当作可以改的来算（下面检查用的是撤回以后的样子）。
        editable = [v for v in self.versions if resource_state(v) in EDITABLE_STATES or v in to_withdraw]
        self.editable_version = editable[0] if editable else None
        reused = self.editable_version["id"] if self.editable_version else None
        self.first_version = not [v for v in self.versions if v["id"] != reused]
        for version in self.versions:
            if version["id"] != reused and (version.get("attributes") or {}).get("versionString") == self.version:
                raise Failure(
                    f"版本 {self.version} 已经提交过了（{resource_state(version)}）。App Store 的每个新版本都要用更大的版本号："
                    "先发布新的 GitHub 版本（打新标签），或者运行时在 version 里填一个更大的版本号。"
                )
        if not self.first_version:
            missing = [locale for locale in self.listing.locales if not self.listing.whats_new.get(locale, (None,))[0]]
            if missing:
                hints = []
                for locale in missing:
                    hint = self.listing.rel(self.listing.root / locale / "whats_new" / f"{self.version}.txt")
                    if locale == CHANGELOG_LOCALE:
                        hint += f"（或者 CHANGELOG.md 里的 ## {self.version}）"
                    hints.append(hint)
                raise Failure(
                    f"{self.version} 不是 App Store 上的第一个版本，要写“此版本的新增内容”，还缺：{'、'.join(hints)}。加上以后再运行。"
                )
        if to_withdraw:
            self.withdraw_review(to_withdraw)

    def withdraw_review(self, versions):
        """把还没审完的版本从审核里撤回（取消它所在的审核提交），等苹果把它变回可以改的状态。"""
        ids = {v["id"] for v in versions}
        names = "、".join(str((v.get("attributes") or {}).get("versionString")) for v in versions)
        self.step(f"撤回审核：版本 {names}")
        submissions, _ = self.api.get_all(f"/v1/apps/{self.app_id}/reviewSubmissions", {
            "filter[platform]": PLATFORM,
            "filter[state]": "WAITING_FOR_REVIEW,IN_REVIEW",
            "limit": 50,
        })
        targets = [s for s in submissions if self.submission_versions(s["id"]) & ids]
        if not targets:
            raise Failure(f"找不到版本 {names} 所在的审核提交，到 App Store Connect 网页上的“App 审核”里撤回以后再运行。")
        for submission in targets:
            payload = {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"canceled": True}}}
            self.api.write("PATCH", f"/v1/reviewSubmissions/{submission['id']}", payload, "撤回")
        self.changed(f"撤回审核：版本 {names}")
        if self.api.dry_run:
            return
        deadline = self.clock() + 600
        while True:
            self.versions, _ = self.api.get_all(
                f"/v1/apps/{self.app_id}/appStoreVersions", {"filter[platform]": PLATFORM, "limit": 200}
            )
            states = {v["id"]: resource_state(v) for v in self.versions}
            if not any(states.get(i) in BUSY_STATES for i in ids):
                break
            if self.clock() > deadline:
                raise Failure(f"撤回了 10 分钟，版本 {names} 还在审核状态（{'、'.join(sorted(set(states[i] for i in ids if i in states)))}），过一会儿再运行。")
            print(f"    等苹果撤回：{'、'.join(states.get(i) or '?' for i in ids)}", flush=True)
            self.sleep(10)
        print(f"    已撤回：{'、'.join(states.get(i) or '?' for i in ids)}")
        if self.editable_version:
            self.editable_version = next((v for v in self.versions if v["id"] == self.editable_version["id"]), self.editable_version)

    def app_attributes(self):
        wanted = self.config["contentRightsDeclaration"]
        self.step("内容版权")
        if (self.app.get("attributes") or {}).get("contentRightsDeclaration") == wanted:
            print("    不用改")
            return
        payload = {"data": {"type": "apps", "id": self.app_id, "attributes": {"contentRightsDeclaration": wanted}}}
        self.api.write("PATCH", f"/v1/apps/{self.app_id}", payload, describe(payload["data"]["attributes"]))
        self.changed(f"内容版权：{wanted}")

    def price(self):
        self.step("价格：免费")
        schedule = (self.api.get(f"/v1/apps/{self.app_id}/appPriceSchedule", allow_404=True) or {}).get("data")
        if schedule:
            # 还没定过价的新 App 也会返回一个价格表（ID 和 App 一样），读它的价格却是 404：当作还没有价格。
            prices, included = self.api.get_all(
                f"/v1/appPriceSchedules/{schedule['id']}/manualPrices", {"include": "appPricePoint,territory", "limit": 200},
                allow_404=True,
            )
            points = {item["id"]: item for item in included if item.get("type") == "appPricePoints"}
            customer = [((points.get(rel_id(p, "appPricePoint")) or {}).get("attributes") or {}).get("customerPrice") for p in prices]
            if customer and all(is_zero(c) for c in customer):
                print("    已经是免费")
                return
        point = None
        for page in self.api.pages(f"/v1/apps/{self.app_id}/appPricePoints", {"filter[territory]": "USA", "limit": 200}):
            point = next((p for p in page.get("data") or [] if is_zero((p.get("attributes") or {}).get("customerPrice"))), None)
            if point:
                break
        if point is None:
            raise Failure("美国的价格点里没有 0（免费）这一档，到网页上的“价格与销售范围”里把价格设成免费")
        payload = {
            "data": {
                "type": "appPriceSchedules",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": self.app_id}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]},
                },
            },
            "included": [{
                "type": "appPrices",
                "id": "${free}",
                "attributes": {"startDate": None},
                "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": point["id"]}}},
            }],
        }
        self.api.write("POST", "/v1/appPriceSchedules", payload, "免费，基准地区美国")
        self.changed("价格：免费")

    def availability(self):
        excluded = set(self.config["excludedTerritories"])
        wanted_new = self.config["availableInNewTerritories"]
        self.step(f"销售范围：除了 {'、'.join(sorted(excluded)) or '（没有）'} 以外的所有国家和地区")
        current = (self.api.get(f"/v1/apps/{self.app_id}/appAvailabilityV2", allow_404=True) or {}).get("data")
        items = []
        if current:
            # 和价格一样，没设过销售范围的新 App 可能返回一个空壳，读它的地区是 404 或者空的：当作还没设过。
            items, _ = self.api.get_all(
                f"/v2/appAvailabilities/{current['id']}/territoryAvailabilities", {"include": "territory", "limit": 200},
                allow_404=True,
            )
        if not items:
            territories, _ = self.api.get_all("/v1/territories", {"limit": 200})
            ids = sorted(t["id"] for t in territories)
            unknown = excluded - set(ids)
            if unknown:
                annotate("warning", f"App Store 的地区里没有 {'、'.join(sorted(unknown))}，检查 config.json 的 excludedTerritories")
            included = [{
                "type": "territoryAvailabilities",
                "id": f"${{{territory}}}",
                "attributes": {"available": territory not in excluded},
                "relationships": {"territory": {"data": {"type": "territories", "id": territory}}},
            } for territory in ids]
            payload = {
                "data": {
                    "type": "appAvailabilities",
                    "attributes": {"availableInNewTerritories": wanted_new},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": self.app_id}},
                        "territoryAvailabilities": {"data": [{"type": item["type"], "id": item["id"]} for item in included]},
                    },
                },
                "included": included,
            }
            shown = len([t for t in ids if t not in excluded])
            self.api.write("POST", "/v2/appAvailabilities", payload, f"{shown} 个国家和地区上架，不上架的：{'、'.join(sorted(excluded & set(ids))) or '没有'}")
            self.changed(f"销售范围：{shown} 个国家和地区（不含 {'、'.join(sorted(excluded))}）")
            return
        if (current.get("attributes") or {}).get("availableInNewTerritories") != wanted_new:
            annotate("warning", "“以后新增的国家和地区自动上架”和 config.json 里的不一样；API 改不了这一项，到网页上的“价格与销售范围”里改")
        fixed = []
        for item in items:
            territory = rel_id(item, "territory")
            if not territory:
                continue
            available = territory not in excluded
            if (item.get("attributes") or {}).get("available") != available:
                payload = {"data": {"type": "territoryAvailabilities", "id": item["id"], "attributes": {"available": available}}}
                self.api.write("PATCH", f"/v1/territoryAvailabilities/{item['id']}", payload, f"{territory} {'上架' if available else '不上架'}")
                fixed.append(f"{territory}{'上架' if available else '不上架'}")
        if fixed:
            self.changed(f"销售范围：{'、'.join(fixed)}")
        else:
            print("    不用改")

    def prepare_version(self):
        self.step(f"版本 {self.version}")
        wanted = {"copyright": self.listing.copyright, "releaseType": self.config["releaseType"]}
        current = self.editable_version
        if current:
            attributes = current.get("attributes") or {}
            update = differences(attributes, {"versionString": self.version, **wanted})
            self.version_id = current["id"]
            if update:
                payload = {"data": {"type": "appStoreVersions", "id": self.version_id, "attributes": update}}
                self.api.write("PATCH", f"/v1/appStoreVersions/{self.version_id}", payload, describe(update))
                if "versionString" in update:
                    self.changed(f"版本号：{attributes.get('versionString')} → {self.version}")
                rest = [key for key in update if key != "versionString"]
                if rest:
                    self.changed(f"版本信息：{'、'.join(rest)}")
            else:
                print(f"    用现有的版本（{resource_state(current)}），不用改")
        else:
            attributes = {"platform": PLATFORM, "versionString": self.version, **wanted}
            payload = {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": attributes,
                    "relationships": {"app": {"data": {"type": "apps", "id": self.app_id}}},
                }
            }
            created = self.api.write("POST", "/v1/appStoreVersions", payload, describe(attributes))
            self.version_id = created["id"]
            self.changed(f"新建版本 {self.version}")
        if self.first_version:
            print("    这是 App Store 上的第一个版本：不填“此版本的新增内容”")

    def app_info(self):
        self.step("App 信息：类别、名称、副标题、隐私政策网址、年龄分级")
        infos, _ = self.api.get_all(
            f"/v1/apps/{self.app_id}/appInfos", {"include": "primaryCategory,secondaryCategory", "limit": 50}
        )
        editable = [info for info in infos if resource_state(info) in EDITABLE_STATES]
        if not editable:
            if self.api.dry_run and self.version_id.startswith(DRY):
                print("    （演练：新建版本以后才有能改的 App 信息，跳过）")
            else:
                annotate("warning", "没有能改的 App 信息（只有准备新版本时才能改），跳过类别、名称和年龄分级")
            return
        info = editable[0]
        relationships = {}
        for key in ("primaryCategory", "secondaryCategory"):
            wanted = self.config.get(key)
            if wanted and rel_id(info, key) != wanted:
                relationships[key] = {"data": {"type": "appCategories", "id": wanted}}
        if relationships:
            payload = {"data": {"type": "appInfos", "id": info["id"], "relationships": relationships}}
            summary = "，".join(f"{key}={value['data']['id']}" for key, value in relationships.items())
            self.api.write("PATCH", f"/v1/appInfos/{info['id']}", payload, summary)
            self.changed(f"类别：{summary}")
        self.app_info_localizations(info["id"])
        self.age_rating(info["id"])

    def app_info_localizations(self, info_id):
        items, _ = self.api.get_all(f"/v1/appInfos/{info_id}/appInfoLocalizations", {"limit": 50})
        existing = {item["attributes"]["locale"]: item for item in items}
        for locale, fields in self.listing.locales.items():
            wanted = {key: fields[key] for key in APP_INFO_FIELDS if fields.get(key)}
            current = existing.get(locale)
            if current is None:
                payload = {
                    "data": {
                        "type": "appInfoLocalizations",
                        "attributes": {"locale": locale, **wanted},
                        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}},
                    }
                }
                try:
                    self.api.write("POST", "/v1/appInfoLocalizations", payload, f"{locale}：{describe(wanted)}")
                    self.changed(f"{locale} App 信息：新建")
                except ApiError as err:
                    # 名称在整个 App Store 里要唯一，被占用时建不成；别的照常做下去。
                    err.report("warning")
                    annotate("warning", f"没能添加 {locale} 的名称和副标题（名称可能已经被别的 App 用了）：换一个名字写进 docs/app-store/listing/{locale}/name.txt")
                continue
            update = differences(current.get("attributes"), wanted)
            if not update:
                continue
            path = f"/v1/appInfoLocalizations/{current['id']}"
            try:
                self.api.write("PATCH", path, self._update_payload("appInfoLocalizations", current["id"], update), f"{locale}：{describe(update)}")
                self.changed(f"{locale} App 信息：{'、'.join(FIELD_NAMES[k] for k in update)}")
            except ApiError as err:
                if "name" not in update:
                    raise
                err.report("warning")
                annotate("warning", f"{locale} 的名称改不成“{wanted['name']}”（可能已经被别的 App 用了），名称先保持原样：换一个名字写进 docs/app-store/listing/{locale}/name.txt")
                update.pop("name")
                if update:
                    self.api.write("PATCH", path, self._update_payload("appInfoLocalizations", current["id"], update), f"{locale}：{describe(update)}")
                    self.changed(f"{locale} App 信息：{'、'.join(FIELD_NAMES[k] for k in update)}")

    @staticmethod
    def _update_payload(kind, resource_id, attributes):
        return {"data": {"type": kind, "id": resource_id, "attributes": attributes}}

    def age_rating(self, info_id):
        declaration = (self.api.get(f"/v1/appInfos/{info_id}/ageRatingDeclaration", allow_404=True) or {}).get("data")
        if not declaration:
            annotate("warning", "读不到年龄分级问卷，到网页上的 App 信息 → 年龄分级里全部选“无”")
            return
        attributes = declaration.get("attributes") or {}
        known = set(AGE_RATING_LEVELS) | set(AGE_RATING_FLAGS) | set(AGE_RATING_UNTOUCHED)
        unknown = sorted(key for key in attributes if key not in known)
        if unknown:
            annotate("warning", f"年龄分级里有脚本不认识的问题：{', '.join(unknown)}。苹果可能又改了问卷：到网页上看一眼，再把它加进 scripts/app-store-connect.py")
        answers = age_rating_answers(attributes)
        if not answers:
            print("    年龄分级：不用改")
            return
        payload = {"data": {"type": "ageRatingDeclarations", "id": declaration["id"], "attributes": answers}}
        self.api.write("PATCH", f"/v1/ageRatingDeclarations/{declaration['id']}", payload, f"{len(answers)} 个问题答“无”或“否”")
        self.changed(f"年龄分级：{len(answers)} 个问题")

    def version_localizations(self):
        extra = "" if self.first_version else "、此版本的新增内容"
        self.step(f"版本的描述、关键词、推广文本、网址{extra}")
        items, _ = self.api.get_all(f"/v1/appStoreVersions/{self.version_id}/appStoreVersionLocalizations", {"limit": 50})
        existing = {item["attributes"]["locale"]: item for item in items}
        for locale, fields in self.listing.locales.items():
            wanted = {key: fields[key] for key in VERSION_FIELDS if fields.get(key)}
            if not self.first_version:
                # App Store 上第一个版本不能填“此版本的新增内容”，苹果会拒绝。
                wanted["whatsNew"] = self.listing.whats_new[locale][0]
            current = existing.get(locale)
            if current is None:
                payload = {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "attributes": {"locale": locale, **wanted},
                        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": self.version_id}}},
                    }
                }
                created = self.api.write("POST", "/v1/appStoreVersionLocalizations", payload, f"{locale}：{describe(wanted)}")
                self.localization_ids[locale] = created["id"]
                self.changed(f"{locale} 版本资料：新建")
                continue
            self.localization_ids[locale] = current["id"]
            update = differences(current.get("attributes"), wanted)
            if update:
                payload = self._update_payload("appStoreVersionLocalizations", current["id"], update)
                self.api.write("PATCH", f"/v1/appStoreVersionLocalizations/{current['id']}", payload, f"{locale}：{describe(update)}")
                self.changed(f"{locale} 版本资料：{'、'.join(FIELD_NAMES[k] for k in update)}")
            else:
                print(f"    {locale}：不用改")

    def screenshots(self):
        files = self.listing.screenshots
        if not files:
            self.step("截图：没有给截图，不动")
            return
        locale = self.listing.primary_locale
        self.step(f"截图（{locale}，{len(files)} 张；其他语言用它）")
        localization_id = self.localization_ids[locale]
        sets, _ = self.api.get_all(
            f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
            {"filter[screenshotDisplayType]": SCREENSHOT_TYPE},
        )
        screenshot_set = next((s for s in sets if (s.get("attributes") or {}).get("screenshotDisplayType") == SCREENSHOT_TYPE), None)
        local = [(path, md5(path)) for path in files]
        if screenshot_set:
            shots, _ = self.api.get_all(f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots", {"limit": 50})
            remote = [(shot.get("attributes") or {}).get("sourceFileChecksum") for shot in shots]
            complete = all(((shot.get("attributes") or {}).get("assetDeliveryState") or {}).get("state") == "COMPLETE" for shot in shots)
            if remote == [checksum for _, checksum in local] and complete:
                print("    和现在的一样，不用重新上传")
                return
            for shot in shots:
                self.api.write("DELETE", f"/v1/appScreenshots/{shot['id']}", summary=(shot.get("attributes") or {}).get("fileName", ""))
        else:
            payload = {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": SCREENSHOT_TYPE},
                    "relationships": {
                        "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}
                    },
                }
            }
            screenshot_set = self.api.write("POST", "/v1/appScreenshotSets", payload, SCREENSHOT_TYPE)
        ids = [self.upload_screenshot(screenshot_set["id"], path, checksum) for path, checksum in local]
        # 按文件名的顺序排好（一张一张传时本来就是这个顺序，这里再确认一次）。
        payload = {"data": [{"type": "appScreenshots", "id": shot_id} for shot_id in ids]}
        try:
            self.api.write("PATCH", f"/v1/appScreenshotSets/{screenshot_set['id']}/relationships/appScreenshots", payload, "按文件名排序")
        except ApiError as err:
            err.report("warning")
            annotate("warning", "截图传好了，但没能调整顺序，到网页上看一眼")
        self.changed(f"截图：上传了 {len(ids)} 张")

    def upload_screenshot(self, set_id, path, checksum):
        data = Path(path).read_bytes()
        payload = {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
            }
        }
        shot = self.api.write("POST", "/v1/appScreenshots", payload, f"{path.name}（{len(data)} 字节）")
        if not self.api.dry_run:
            for operation in (shot.get("attributes") or {}).get("uploadOperations") or []:
                offset, length = operation.get("offset", 0), operation.get("length", len(data))
                self.api.upload(operation, data[offset:offset + length])
        commit = {"data": {"type": "appScreenshots", "id": shot["id"], "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}}
        self.api.write("PATCH", f"/v1/appScreenshots/{shot['id']}", commit, f"{path.name} 传完了")
        if self.api.dry_run:
            return shot["id"]
        deadline = self.clock() + 10 * 60
        while True:
            current = (self.api.get(f"/v1/appScreenshots/{shot['id']}") or {}).get("data") or {}
            delivery = (current.get("attributes") or {}).get("assetDeliveryState") or {}
            if delivery.get("state") == "COMPLETE":
                return shot["id"]
            if delivery.get("state") == "FAILED":
                reasons = "；".join(f"{e.get('code', '')} {e.get('description', '')}".strip() for e in delivery.get("errors") or [])
                raise Failure(f"App Store Connect 处理截图 {path.name} 失败：{reasons or '没有说明'}")
            if self.clock() > deadline:
                raise Failure(f"截图 {path.name} 传上去 10 分钟了还没处理完，过一会儿再运行一次")
            self.sleep(5)

    def review_detail(self):
        self.step("App 审核信息：备注、不需要登录" + ("、联系人" if self.contact else ""))
        wanted = {"notes": self.listing.review_notes, "demoAccountRequired": False, **(self.contact or {})}
        current = (self.api.get(f"/v1/appStoreVersions/{self.version_id}/appStoreReviewDetail", allow_404=True) or {}).get("data")
        if current:
            update = differences(current.get("attributes"), wanted)
            if update:
                payload = self._update_payload("appStoreReviewDetails", current["id"], update)
                try:
                    self.api.write("PATCH", f"/v1/appStoreReviewDetails/{current['id']}", payload, describe(update))
                    self.changed(f"审核信息：{'、'.join(update)}")
                except ApiError as err:
                    # 和价格、销售范围一样，没填过的可能只是个空壳，改不了就新建。
                    if err.status != 404:
                        raise
                    current = None
            else:
                print("    不用改")
        if not current:
            payload = {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": wanted,
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": self.version_id}}},
                }
            }
            self.api.write("POST", "/v1/appStoreReviewDetails", payload, describe(wanted))
            self.changed("审核信息：新建")
        if not self.contact and not ((current or {}).get("attributes") or {}).get("contactEmail"):
            annotate("warning", "还没有审核联系人：设置 Secret APPSTORE_REVIEW_CONTACT（四行：名、姓、电话、邮箱），或者在网页上的“App 审核信息”里填，不然提交不了审核")

    def attach_build(self):
        if self.build_number:
            self.step(f"构建 {self.build_number}")
            build = self.wait_for_build()
        elif self.attach_latest:
            self.step(f"构建：{self.version} 最新的可用构建")
            response = self.api.get("/v1/builds", {
                "filter[app]": self.app_id,
                "filter[preReleaseVersion.version]": self.version,
                "filter[preReleaseVersion.platform]": PLATFORM,
                "filter[processingState]": "VALID",
                "filter[expired]": "false",
                "sort": "-uploadedDate",
                "limit": 1,
            }) or {}
            build = (response.get("data") or [None])[0]
            if build is None:
                print(f"    还没有 {self.version} 的可用构建，先不选")
        else:
            build = None
        current = (self.api.get(f"/v1/appStoreVersions/{self.version_id}/relationships/build", allow_404=True) or {}).get("data")
        self.attached_build = current.get("id") if isinstance(current, dict) else None
        if build is None:
            return
        attributes = build.get("attributes") or {}
        print(f"    构建 {attributes.get('version')}" + (f"（上传于 {attributes['uploadedDate']}）" if attributes.get("uploadedDate") else ""))
        if attributes.get("usesNonExemptEncryption") is None:
            # Info.plist 里已经写了 ITSAppUsesNonExemptEncryption = NO，一般不会走到这里。
            payload = {"data": {"type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}}
            self.api.write("PATCH", f"/v1/builds/{build['id']}", payload, "不使用非豁免的加密")
            self.changed("出口合规：不使用非豁免的加密")
        if self.attached_build != build["id"]:
            payload = {"data": {"type": "builds", "id": build["id"]}}
            self.api.write("PATCH", f"/v1/appStoreVersions/{self.version_id}/relationships/build", payload, f"选上构建 {attributes.get('version')}")
            self.attached_build = build["id"]
            self.changed(f"构建：{attributes.get('version')}")
        else:
            print("    已经选的就是它")

    def wait_for_build(self):
        params = {
            "filter[app]": self.app_id,
            "filter[version]": self.build_number,
            "filter[preReleaseVersion.version]": self.version,
            "filter[preReleaseVersion.platform]": PLATFORM,
            "limit": 10,
        }
        start = self.clock()
        deadline = start + self.wait_minutes * 60
        while True:
            builds, _ = self.api.get_all("/v1/builds", params)
            build = builds[0] if builds else None
            state = (build.get("attributes") or {}).get("processingState") if build else None
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise Failure(f"构建 {self.build_number} 处理失败（{state}）：看 App Store Connect 发来的邮件里说的原因，改好后重新上传")
            if self.api.dry_run:
                print(f"    （演练：不等）构建 {self.build_number} 现在是 {state or '还没出现'}")
                return None
            if self.clock() >= deadline:
                raise Failure(
                    f"等了 {self.wait_minutes} 分钟，构建 {self.build_number} 还没处理完（{state or '还没出现'}）。"
                    "处理完以后再运行一次 app-store 工作流：build 选 none、勾上 listing，会选上最新的可用构建。"
                )
            waited = int((self.clock() - start) // 60)
            print(f"    构建 {self.build_number}：{state or '还没出现'}，已经等了 {waited} 分钟", flush=True)
            self.sleep(30)

    def submit_for_review(self):
        self.step("提交审核")
        if not self.attached_build:
            raise Failure(f"版本 {self.version} 还没有选构建，提交不了审核。先上传构建（build 选 upload），处理完以后再提交。")
        submissions, _ = self.api.get_all(f"/v1/apps/{self.app_id}/reviewSubmissions", {
            "filter[platform]": PLATFORM,
            "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES",
            "limit": 50,
        })
        for unresolved in (s for s in submissions if (s.get("attributes") or {}).get("state") == "UNRESOLVED_ISSUES"):
            if self.version_id in self.submission_versions(unresolved["id"]):
                raise Failure(
                    f"版本 {self.version} 上一次提交的审核被退回了，还没处理（UNRESOLVED_ISSUES）：到 App Store Connect 网页上的"
                    "“App 审核”里看审核员的说明，回复或者改好以后在那里重新提交。资料和构建已经按仓库更新好了。"
                )
        submission = next((s for s in submissions if (s.get("attributes") or {}).get("state") == "READY_FOR_REVIEW"), None)
        try:
            if submission is None:
                payload = {
                    "data": {
                        "type": "reviewSubmissions",
                        "attributes": {"platform": PLATFORM},
                        "relationships": {"app": {"data": {"type": "apps", "id": self.app_id}}},
                    }
                }
                submission = self.api.write("POST", "/v1/reviewSubmissions", payload, PLATFORM)
            if self.version_id not in self.submission_versions(submission["id"]):
                payload = {
                    "data": {
                        "type": "reviewSubmissionItems",
                        "relationships": {
                            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": self.version_id}},
                        },
                    }
                }
                self.api.write("POST", "/v1/reviewSubmissionItems", payload, f"版本 {self.version}")
            payload = {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}}
            self.api.write("PATCH", f"/v1/reviewSubmissions/{submission['id']}", payload, "提交")
        except ApiError as err:
            err.report()
            raise Failure(SUBMIT_HINT) from None
        self.changed(f"已提交审核：版本 {self.version}")

    def submission_versions(self, submission_id):
        """一个审核提交里（没被移除的）App Store 版本的 ID。"""
        items, _ = self.api.get_all(f"/v1/reviewSubmissions/{submission_id}/items", {"include": "appStoreVersion", "limit": 50})
        return {rel_id(i, "appStoreVersion") for i in items if (i.get("attributes") or {}).get("state") != "REMOVED"} - {None}

    def summary(self):
        prefix = "演练，" if self.api.dry_run else ""
        print()
        if self.changes:
            print(f"==> {prefix}改了这些：")
            for change in self.changes:
                print(f"    • {change}")
            text = f"{prefix}版本 {self.version}：" + "；".join(self.changes)
        else:
            print(f"==> {prefix}App Store Connect 上已经和仓库里的资料一样，什么都没改")
            text = f"{prefix}版本 {self.version}：App Store Connect 上已经和仓库里的资料一样"
        if not self.submit:
            text += "。还没有提交审核"
        annotate("notice", text, title="App Store Connect")


# ---------------------------------------------------------------- 命令行


def main(argv=None):
    parser = argparse.ArgumentParser(description="检查 App Store 资料文件，或者把它们填进 App Store Connect。")
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="只检查 docs/app-store/listing 里的文件，不联网")
    check.add_argument("--version", help="也检查这个版本的“此版本的新增内容”")
    check.add_argument("--screenshots", help="截图文件夹（默认 docs/app-store/listing/screenshots/<主要语言>）")
    sync = commands.add_parser("sync", help="把资料填进 App Store Connect，选上构建，需要时提交审核")
    sync.add_argument("--version", required=True, help="App Store 上的版本号，比如 0.49.0")
    which = sync.add_mutually_exclusive_group()
    which.add_argument("--build", help="选这个构建号的构建（比如 612.3），没处理完时等着")
    which.add_argument("--attach-latest-build", action="store_true", help="选这个版本最新的可用构建，没有就不选")
    sync.add_argument("--wait-build-minutes", type=int, default=0, help="--build 时最多等几分钟（默认不等）")
    sync.add_argument("--submit", action="store_true", help="最后提交审核")
    sync.add_argument("--withdraw-review", action="store_true",
                      help="有版本还在等审核或审核中时，先把它撤回（用这个版本替换它），而不是停下")
    sync.add_argument("--screenshots", help="截图文件夹（默认 docs/app-store/listing/screenshots/<主要语言>）")
    sync.add_argument("--dry-run", action="store_true", help="只读不写，打印要写的内容")
    args = parser.parse_args(argv)

    try:
        listing = run_check(args.version, args.screenshots)
        if args.command == "check":
            return 0
        contact = None
        if os.environ.get("APPSTORE_REVIEW_CONTACT", "").strip():
            contact = parse_contact(os.environ["APPSTORE_REVIEW_CONTACT"])
        with tempfile.TemporaryDirectory() as workdir:
            key_id, issuer_id, key_path = load_key(os.environ, workdir)
            api = Api(TokenSource(key_id, issuer_id, key_path), dry_run=args.dry_run)
            Sync(
                api, listing, args.version, build=args.build, wait_minutes=args.wait_build_minutes,
                attach_latest=args.attach_latest_build, submit=args.submit, contact=contact,
                withdraw=args.withdraw_review,
            ).run()
        return 0
    except ApiError as err:
        err.report()
        if err.status == 401:
            annotate("error", "App Store Connect 不认这个 API 密钥：检查 ASC_KEY_ID、ASC_ISSUER_ID 和 ASC_KEY_P8 是不是同一把密钥，密钥有没有被撤销")
        elif err.status == 403:
            annotate("error", "API 密钥的权限不够：在 App Store Connect 的“用户和访问 → 集成”里给它“App 管理”（App Manager）或更高的权限")
        return 1
    except Failure as err:
        annotate("error", str(err))
        return 1


if __name__ == "__main__":
    sys.exit(main())
