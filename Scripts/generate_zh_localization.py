from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
EN_PATH = ROOT / "Resources/en.lproj/Localizable.strings"
ZH_DIR = ROOT / "Resources/zh-Hans.lproj"
ZH_PATH = ZH_DIR / "Localizable.strings"
SWIFT_ROOT = ROOT / "Source/Classes/SwiftUI"

KEY_VALUE_RE = re.compile(r"\"((?:\\.|[^\"\\])*)\"\s*=\s*\"((?:\\.|[^\"\\])*)\"\s*;")
LITERAL_RE = re.compile(
    r"\b(?:Text|Button|Label|Picker|SecureField|Toggle|NavigationLink|ProgressView|LabeledContent|TextField|Menu)\(\s*\"((?:\\.|[^\"\\])*)\""
)
NAV_TITLE_RE = re.compile(r"\.navigationTitle\(\s*\"((?:\\.|[^\"\\])*)\"\s*\)")
TITLE_PROP_RE = re.compile(r"var\s+title\s*:\s*String\s*\{\s*\"((?:\\.|[^\"\\])*)\"\s*\}")
ALERT_RE = re.compile(r"\.alert\(\s*\"((?:\\.|[^\"\\])*)\"")
NSLOCALIZED_RE = re.compile(
    r'NSLocalizedString\(\s*"((?:\\.|[^"\\])*)"\s*,\s*comment:\s*"[^"]*"\s*\)'
)
PLACEHOLDER_RE = re.compile(
    r"%(?:\d+\$)?[+#0\- ]*(?:\d+)?(?:\.\d+)?[hlLzjt]*[@diuoxXfFeEgGaAcCsSp%]"
)
PH_TOKEN_RE = re.compile(r"__\s*PH(\d+)\s*__")
ESC_TOKEN_RE = re.compile(r"__\s*NL\s*__")

# 这里放关键 UI 文案的人工翻译（优先级最高）
MANUAL_TRANSLATIONS = {
    "%@ connected": "%@ 已连接",
    "%@ deafened": "%@ 已自我闭听",
    "%@ disconnected": "%@ 已断开连接",
    "%@ moved to %@": "%@ 移动到了 %@",
    "%@ muted": "%@ 关闭了麦克风",
    "%@ started listening to your channel": "%@ 开始监听你的频道",
    "%@ stopped listening to your channel": "%@ 停止监听你的频道",
    "%@ undeafened": "%@ 已取消自我闭听",
    "%@ unmuted": "%@ 开启了麦克风",
    "Acknowledgements": "致谢",
    "Add to Widget": "添加到小组件",
    "Added to Widget": "已添加到小组件",
    "Advanced": "高级",
    "Appearance": "外观",
    "Clear Messages": "清空消息",
    "(Message with image attachment)": "（含图片附件的消息）",
    "(Message with image attachments)": "（含图片附件的消息）",
    "Allow child channels to inherit": "允许子频道继承",
    "Apply to sub-channels": "应用于子频道",
    "Apply to this channel": "应用于此频道",
    "Certificate Info": "证书信息",
    "Bound Certificate": "绑定证书",
    "Channel Listening": "频道监听",
    "Channel Password": "频道密码",
    "Channel name": "频道名称",
    "Compressing and Sending...": "正在压缩并发送...",
    "Create Channel": "创建频道",
    "Properties": "属性",
    "Edit Favourite": "编辑收藏服务器",
    "New Favourite": "新建收藏服务器",
    "Delete Certificate?": "删除证书？",
    "Enter channel name": "输入频道名称",
    "Enter description...": "请输入文本",
    "Hostname or IP": "主机名或 IP",
    "Enter password": "输入密码",
    "Export Certificate": "导出证书",
    "Export Result": "导出结果",
    "Force TCP Mode": "强制 TCP 模式",
    "Group name": "组名称",
    "Handoff Profile": "接力设置",
    "Import": "导入",
    "Import Certificate": "导入证书",
    "Import Failed": "导入失败",
    "Left Shift": "左 Shift",
    "Right Shift": "右 Shift",
    "Left Option": "左 Option",
    "Right Option": "右 Option",
    "Left Control": "左 Control",
    "Right Control": "右 Control",
    "Left Command": "左 Command",
    "Right Command": "右 Command",
    "Space": "空格",
    "Return": "回车",
    "Tab": "制表键",
    "Inherit ACLs from parent": "从父频道继承 ACL",
    "Inherit members from parent": "从父组继承成员",
    "Inherited": "继承",
    "Inheritable": "可继承",
    "Here": "本频道",
    "Subs": "子频道",
    "Property ACL": "属性 ACL",
    "Property": "属性",
    "License": "许可协议",
    "Legal": "法律协议",
    "Loading ACLs...": "正在加载 ACL...",
    "Loading Groups...": "正在加载组...",
    "Moved by Admin": "被管理员移动",
    "Mute / Deafen": "静音/闭听",
    "Mute / Unmute": "静音 / 取消静音",
    "Deafen / Undeafen": "闭听 / 取消闭听",
    "Mute/Unmute": "静音/取消静音",
    "Deafen/Undeafen": "闭听/取消闭听",
    "Mute": "静音",
    "Unmute": "取消静音",
    "Deafen": "闭听",
    "Undeafen": "取消闭听",
    "Mute Self": "关闭麦克风",
    "Unmute Self": "开启麦克风",
    "Deafen Self": "自我闭听",
    "Undeafen Self": "取消自我闭听",
    "Mute and deafen": "静音并闭听",
    "Unmute and undeafen": "取消静音和闭听",
    "Or enter custom group": "或输入自定义组",
    "%@ on %@:%@": "%@ 在 %@:%@",
    "%i of %i": "%i / %i",
    "%d members": "%d 个成员",
    "+%d inherited": "+%d 个继承",
    "PM to %@": "发给 %@ 的私信",
    "PM from %@": "来自 %@ 的私信",
    "Private Messages": "私聊消息",
    "Visual": "可视化",
    "English": "英语",
    "Chinese (Simplified)": "简体中文",
    "System Default": "跟随系统",
    "Follow System": "跟随系统",
    "Light": "浅色",
    "Dark": "深色",
    "Automatic": "自动",
    "Source": "源码",
    "Mode": "模式",
    "Favourite Servers": "服务器收藏夹",
    "Join a Server": "加入服务器",
    "Choose a favourite server to connect quickly": "选择一个收藏的服务器以快速连接",
    "Your saved servers": "你保存的服务器",
    "Favourite": "收藏夹",
    "Servers": "服务器",
    "Recent Connections": "最近连接",
    "Delete": "删除",
    "Disconnect": "断开连接",
    "No recent connections.": "暂无最近连接。",
    "Notifications will be sent when the app is in the background.": "应用在后台时将发送通知。",
    "Local Network": "局域网",
    "Welcome to Mumble": "欢迎使用 Mumble",
    "Let's quickly tune your voice activity threshold for better automatic mic detection.": "让我们快速调节语音激活阈值，以获得更好的自动麦克风检测效果。",
    "Input Device": "输入设备",
    "Connecting...": "正在连接...",
    "Reconnecting...": "正在重连...",
    "Follow System Default (%@)": "跟随系统默认（%@）",
    "No Input Device": "无输入设备",
    "Selected microphone is unavailable, automatically switched to Follow System.": "所选麦克风不可用，已自动切换为跟随系统。",
    "Detection Mode": "检测模式",
    "Amplitude": "振幅",
    "Signal to Noise": "信噪比",
    "SNR requires preprocessing. It will be enabled automatically.": "SNR 需要预处理，将自动启用。",
    "Live Input Level": "实时输入电平",
    "VAD Below": "静音阈值",
    "VAD Above": "语音阈值",
    "Silence Below": "静音阈值",
    "Speech Above": "语音阈值",
    "Silence Hold": "静音保持",
    "Silence Below: %d%%": "静音阈值：%d%%",
    "Speech Above: %d%%": "语音阈值：%d%%",
    "Silence Hold: %d ms": "静音保持：%d 毫秒",
    "Silence Below: input under this level is treated as silence.": "静音阈值：低于此值会被视为静音。",
    "Speech Above: input over this level is treated as speech.": "语音阈值：高于此值会被视为语音。",
    "Silence Hold: when input stays below Silence Below for this duration, it finally switches to silent.": "静音保持：当输入持续低于静音阈值达到该时长后，才会切换为静音。",
    "Below: input under this level is treated as silence.\\\\nAbove: input over this level is treated as speech.\\\\nSilence Hold: when input stays below Below for this duration, it finally switches to silent.": "静音阈值：低于此值会被视为静音。\\\\n语音阈值：高于此值会被视为语音。\\\\n静音保持：当输入持续低于静音阈值达到该时长后，才会切换为静音。",
    "Continue": "继续",
    "No Server Connected": "未连接服务器",
    "Select a server from the sidebar to start chatting.": "从侧边栏选择一个服务器开始聊天。",
    "Cancel": "取消",
    "OK": "确定",
    "Done": "完成",
    "Save": "保存",
    "Edit": "编辑",
    "Comment": "备注",
    "Description": "描述",
    "Loading...": "加载中...",
    "No comment set.": "未设置备注。",
    "No description set.": "未设置描述。",
    "Send": "发送",
    "Confirm Image": "确认图片",
    "High Quality Mode": "高质量模式",
    "Less Compressed": "低压缩",
    "Audio Settings for %@": "%@ 的音频设置",
    "Access denied. You may try entering a password.": "访问被拒绝。你可以尝试输入密码。",
    "Language": "语言",
    "Language Changed": "语言已更改",
    "Some texts will fully update after restarting the app.": "部分文本需要重启应用后才会完全更新。",
    "Local Volume: %d%%": "本地音量：%d%%",
    "Missing": "缺失",
    "Someone": "某人",
    "System": "系统",
    "Unknown": "未知",
    "Unknown Channel": "未知频道",
    "Unknown User": "未知用户",
    "Unknown Server": "未知服务器",
    "You": "你",
    "You moved to channel %@": "你已移动到频道 %@",
    "You were moved to channel %@ by %@": "你被 %@ 移动到了频道 %@",
    "[Image]": "[图片]",
    "admin": "管理员",
    "another device": "另一台设备",
    "in %@": "在 %@ 中",
    "this server": "此服务器",
    "this channel": "此频道",
    "Channel": "频道",
    "User": "用户",
    "user": "用户",
    "Root": "根频道",
    "Remove from Widget": "从小组件移除",
    "Removed from Widget": "已从小组件移除",
    "Session handed off to %@": "会话已接力到 %@",
    "Show On-Screen Talk Button": "在屏幕上显示说话按钮",
    "Push-to-Talk Key": "说话按键",
    "Sidetone": "返听",
    "Sidetone (Hear yourself)": "返听（听到自己的声音）",
    "Sidetone Volume": "返听音量",
    "Speakerphone Mode": "扬声器模式",
    "Sync Local User Volume on Handoff": "接力时同步本地用户音量",
    "Temporary Channel": "临时频道",
    "Third Party Libraries": "第三方库",
    "Type a message...": "输入消息...",
    "Private Message": "私聊消息",
    "User Messages": "用户消息",
    "Welcome Message": "欢迎消息",
    "Message too long": "消息过长",
    "Processing": "音频处理",
    "User Joined (Other Channels)": "用户加入（其他频道）",
    "User Joined (Same Channel)": "用户加入（同频道）",
    "User Left (Other Channels)": "用户离开（其他频道）",
    "User Left (Same Channel)": "用户离开（同频道）",
    "User Moved Channel": "用户切换频道",
    "Username or User ID": "用户名或用户 ID",
    "Invalid password or corrupted file.": "密码错误或文件已损坏。",
    "Me": "我",
    "Volume": "音量",
    "Reset to Default": "恢复默认",
    "Audio": "音频",
    "General": "通用",
    "Input Setting": "输入设置",
    "Advanced & Network": "高级与网络",
    "Notifications": "通知",
    "Push Notifications": "推送通知",
    "Handoff": "接力",
    "Certificates": "证书",
    "About Mumble": "关于 Mumble",
    "Mumble macOS v%@": "Mumble macOS v%@",
    "Mumble iOS v%@": "Mumble iOS v%@",
    "No Favourite Servers": "暂无收藏的服务器",
    "add a favourite server": "添加收藏的服务器",
    "Tap + to add a favourite server": "点击 + 添加收藏的服务器",
    "Server Details": "服务器详情",
    "Authentication": "认证",
    "Certificate": "证书",
    "None": "无",
    "Missing bound certificate": "缺少绑定证书",
    "Registered Server": "已注册服务器",
    "Registered": "已注册",
    "Muted": "静音",
    "Deafened": "闭听",
    "Server Deafen": "服务器闭听",
    "Server Undeafen": "服务器取消闭听",
    "Mumble — Muted": "Mumble — 静音",
    "Mumble — Deafened": "Mumble — 闭听",
    "Certificate Missing": "证书缺失",
    "Address and Port are locked because this server is registered with a secure certificate.": "该服务器已绑定安全证书，地址和端口已锁定。",
    "Fields are unlocked because the associated certificate is missing.": "由于关联证书缺失，字段已解锁。",
    "Identity fields are locked to maintain certificate integrity.": "为保持证书一致性，身份字段已锁定。",
    "You can update your username/password since the original certificate is lost.": "由于原证书丢失，你可以修改用户名/密码。",
    "You can manually bind a certificate for this profile. The selected certificate will be used when connecting from Favourite Servers.": "你可以为该配置手动绑定证书。从服务器收藏夹连接时将使用所选证书。",
    "Channel Name": "频道名称",
    "Settings": "设置",
    "Position": "位置",
    "(sort order)": "（排序）",
    "Max Users": "最大用户数",
    "(0 = unlimited)": "（0 = 不限制）",
    "Port": "端口",
    "Password": "密码",
    "Optional": "可选",
    "(optional)": "（可选）",
    "Create": "创建",
    "Close": "关闭",
    "(has password)": "（有密码）",
    "Info": "信息",
    "Channel ID": "频道 ID",
    "Type": "类型",
    "Temporary": "临时",
    "Save Changes": "保存修改",
    "Delete Channel": "删除频道",
    "Save ACL": "保存 ACL",
    "No ACL entries": "没有 ACL 条目",
    "Add ACL Entry": "添加 ACL 条目",
    "No group entries": "没有组条目",
    "Add Group": "添加组",
    "Group": "组",
    "User ID": "用户 ID",
    "Target": "目标",
    "Scope": "范围",
    "Permissions": "权限",
    "Group Name": "组名称",
    "Inheritance": "继承",
    "Members (%d)": "成员（%d）",
    "Excluded Members (%d)": "排除成员（%d）",
    "Inherited Members (%d)": "继承成员（%d）",
    "Remove Member": "移除成员",
    "No": "否",
    "Yes": "是",
    # Previously untranslated long texts
    "Are you sure you want to delete all importable certificates?\\n\\nCertificates already imported into Mumble will not be touched.": "确定要删除所有可导入证书吗？\\n\\n已导入到 Mumble 的证书不会受到影响。",
    "Are you sure you want to delete this certificate chain?\\n\\nIf you don't have a backup, this will permanently remove any rights associated with the certificate chain on any Mumble servers.": "确定要删除此证书链吗？\\n\\n如果你没有备份，这将永久移除该证书链在所有 Mumble 服务器上的相关权限。",
    "Banned by %@ for reason: \\\"%@\\\"": "你已被 %@ 封禁，原因：\\\"%@\\\"",
    "Kicked by %@ for reason: \\\"%@\\\"": "你已被 %@ 踢出，原因：\\\"%@\\\"",
    "Continuous": "自由语音",
    "Push-to-Talk": "按键说话",
    "Push-to-Talk Settings": "按键说话设置",
    "In Continuous mode, Mumble will\\ncontinuously transmit all recorded audio.\\n": "在自由语音模式下，Mumble 会\\n持续发送所有录制到的音频。\\n",
    "In Push-to-Talk mode, touch the mouth\\nicon to speak to other people when\\nconnected to a server.\\n": "在按键说话模式下，连接服务器后\\n按住麦克风图标即可与他人通话。\\n",
    "In Voice Activity mode, Mumble transmits\\nyour voice when it senses you talking.\\nFine-tune it below:\\n": "在语音激活模式下，Mumble 检测到你说话时\\n会自动发送语音。\\n可在下方微调：\\n",
    "Signal to Noise (SNR): detects speech by comparing voice against background noise. Better in noisy environments.": "信噪比（SNR）：通过比较语音与背景噪声来检测说话，在嘈杂环境下更稳定。",
    "Amplitude: detects speech by raw input loudness. Simpler and usually more responsive in quiet environments.": "振幅：通过原始输入音量来检测说话，设置更简单，通常在安静环境下响应更快。",
    "Mumble was unable to import the certificate.\\nError Code: %li": "Mumble 无法导入该证书。\\n错误代码：%li",
    "The TLS connection was closed due to an error.\\n\\nThe server might be temporarily rejecting your connection because you have attempted to connect too many times in a row.": "TLS 连接因错误被关闭。\\n\\n服务器可能因你短时间内连接过于频繁而暂时拒绝连接。",
    "To calibrate the voice activity correctly, adjust the sliders so that:\\n\\n1. The first few utterances you make are inside the green area.\\n2. While talking, the bar should stay inside the yellow area.\\n3. When not speaking, the bar should stay inside the red area.": "要正确校准语音激活，请调整滑块使：\\n\\n1. 开始说话时，音量条进入绿色区域。\\n2. 说话过程中，音量条保持在黄色区域。\\n3. 不说话时，音量条保持在红色区域。",
    "To import your own certificate into\\nMumble, please transfer them to your\\ndevice using iTunes File Transfer.": "若要将你自己的证书导入\\nMumble，请通过 iTunes 文件传输\\n将证书复制到你的设备。",
    "You are about to register yourself on this server. This cannot be undone, and your username cannot be changed once this is done. You will forever be known as '%@' on this server.\\n\\nAre you sure you want to register yourself?": "你将要在此服务器上注册自己。此操作不可撤销，完成后用户名也无法修改。你在该服务器上将永久使用“%@”这个名称。\\n\\n确定要注册吗？",
    # Plural-like placeholders
    "%lu\\nppl": "%lu\\n人",
    "%u\\nppl": "%u\\n人",
}

# 部分文本的直接修正（覆盖 seed）
VALUE_FIXUPS = {
    "(Empty body)": "(空正文)",
    "(Empty)": "(空)",
    "(No reason)": "(无原因)",
    "(No Server)": "(无服务器)",
    "Mumble": "Mumble",
    "Mumble Server": "Mumble 服务器",
    "Mumble User": "Mumble 用户",
}


def strings_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\"", "\\\"")


def parse_strings(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-16")
    return {m.group(1): m.group(2) for m in KEY_VALUE_RE.finditer(text)}


def parse_en_keys() -> list[str]:
    return list(parse_strings(EN_PATH).keys())


def collect_swiftui_literals() -> set[str]:
    keys: set[str] = set()
    for path in SWIFT_ROOT.rglob("*.swift"):
        content = path.read_text(encoding="utf-8")
        for regex in (LITERAL_RE, NAV_TITLE_RE, TITLE_PROP_RE, ALERT_RE, NSLOCALIZED_RE):
            for match in regex.finditer(content):
                literal = match.group(1)
                if "\\(" in literal:
                    continue
                if literal == "":
                    continue
                keys.add(literal)
    return keys


def placeholders_from_key(key: str) -> list[str]:
    return PLACEHOLDER_RE.findall(key)


def restore_placeholder_tokens(value: str, key: str) -> str:
    placeholders = placeholders_from_key(key)

    def replace_ph(match: re.Match) -> str:
        index = int(match.group(1))
        if 0 <= index < len(placeholders):
            return placeholders[index]
        return match.group(0)

    value = PH_TOKEN_RE.sub(replace_ph, value)
    value = ESC_TOKEN_RE.sub(r"\n", value)
    return value


def normalize_value(value: str) -> str:
    # 保证 Mumble 始终作为产品名不翻译
    value = value.replace("曼布尔", "Mumble").replace("芒布尔", "Mumble")
    value = value.replace("mumble", "Mumble")
    value = value.replace("Mumble 的 iOS 版", "Mumble for iOS")
    value = value.replace("Mumble 的 macOS 版", "Mumble for macOS")

    # 清理历史错误 token
    value = value.replace("zzSO", "(空正文)").replace("(zz)", "(空)")
    value = value.replace("  ", " ").strip()
    return value


def get_translation(key: str, seed_map: dict[str, str]) -> str:
    if key == "%lu\\nppl":
        return "%lu\\n人"
    if key == "%u\\nppl":
        return "%u\\n人"
    if key.startswith("Below: input under this level is treated as silence."):
        return "静音阈值：低于此值会被视为静音。\\n语音阈值：高于此值会被视为语音。\\n静音保持：当输入持续低于静音阈值达到该时长后，才会切换为静音。"

    if key in MANUAL_TRANSLATIONS:
        return MANUAL_TRANSLATIONS[key]
    if key in VALUE_FIXUPS:
        return VALUE_FIXUPS[key]

    seed = seed_map.get(key)
    if seed:
        seed = restore_placeholder_tokens(seed, key)
        seed = normalize_value(seed)
        return seed

    # 无翻译时 fallback 原文，避免生成空值
    return key


def main():
    seed_map = parse_strings(ZH_PATH)

    format_keys = {
        "Follow System Default (%@)",
        "Mic Volume: %d%%",
        "Silence Below: %d%%",
        "Speech Above: %d%%",
        "Silence Hold: %d ms",
        "Mumble macOS v%@",
        "Mumble iOS v%@",
        "Audio Settings for %@",
        "Local Volume: %d%%",
        "PM to %@",
        "PM from %@",
        "%@ deafened",
        "%@ undeafened",
        "%@ muted",
        "%@ unmuted",
        "%d user(s)",
        "Parent: %@",
        "ID: %@",
        "Members (%d)",
        "Excluded Members (%d)",
        "Inherited Members (%d)",
        "%d members",
        "+%d inherited",
        "Moving %@ - tap a channel",
        "To: %@",
        "Version %@ (Build %@)",
        "Expires: %@",
        "SHA1: %@",
        "Are you sure you want to delete '%@'?",
        "Hostname or IP",
        "Optional",
        "Space",
        "Return",
        "Tab",
        "Left Shift",
        "Right Shift",
        "Left Option",
        "Right Option",
        "Left Control",
        "Right Control",
        "Left Command",
        "Right Command",
        "Properties",
        "Property ACL",
        "Property",
    }

    all_keys = sorted(set(parse_en_keys()) | collect_swiftui_literals() | format_keys)
    print(f"Total keys: {len(all_keys)}")

    lines = ["/* Simplified Chinese localization (offline/manual) */"]
    for key in all_keys:
        value = get_translation(key, seed_map)
        lines.append(f"\"{strings_escape(key)}\" = \"{strings_escape(value)}\";")

    ZH_DIR.mkdir(parents=True, exist_ok=True)
    output = "\n".join(lines) + "\n"
    ZH_PATH.write_text(output, encoding="utf-16")
    print(f"Wrote: {ZH_PATH}")
    print(f"Total entries: {len(all_keys)}")


if __name__ == "__main__":
    main()
