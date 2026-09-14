// MeetingQ - 本地优先的 AI 会议助手（被叫提醒 + 智能纪要）
// Copyright (C) 2026 MeetingQ contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Cantonese (LSHK Jyutping) romanization matching for name detection.
/// Tone numbers are stripped — matching is toneless, same as PinyinHelper.
/// Table covers common Hong Kong surname/given-name characters in both
/// traditional and simplified forms. Characters not in the table simply
/// fall back to exact-match only (no false positives).
public enum JyutpingHelper {
    private static let table: [Character: String] = [
        "阿": "aa", "爱": "oi", "愛": "oi", "安": "on",
        "白": "baak", "百": "baak", "柏": "baak", "班": "baan",
        "宝": "bou", "寶": "bou", "保": "bou", "包": "baau",
        "北": "bak", "彬": "ban", "斌": "ban", "冰": "bing",
        "波": "bo", "博": "bok", "伯": "baak",
        "蔡": "coi", "才": "coi", "彩": "coi", "曹": "cou", "岑": "sam",
        "超": "ciu", "晨": "san", "陈": "can", "陳": "can", "辰": "san",
        "程": "cing", "成": "sing", "诚": "sing", "誠": "sing", "承": "sing",
        "冲": "cung", "沖": "cung", "崇": "sung", "初": "co", "楚": "co",
        "春": "ceon", "纯": "seon", "純": "seon", "慈": "ci", "聪": "cung", "聰": "cung",
        "崔": "ceoi", "翠": "ceoi",
        "达": "daat", "達": "daat", "大": "daai", "戴": "daai", "代": "doi",
        "丹": "daan", "淡": "daam", "当": "dong", "當": "dong", "党": "dong", "黨": "dong",
        "道": "dou", "导": "dou", "導": "dou", "德": "dak",
        "邓": "dang", "鄧": "dang", "灯": "dang", "燈": "dang", "登": "dang",
        "迪": "dik", "帝": "dai", "电": "din", "電": "din",
        "丁": "ding", "定": "ding", "鼎": "ding", "东": "dung", "東": "dung",
        "董": "dung", "冬": "dung", "杜": "dou", "段": "dyun", "多": "do",
        "恩": "jan", "尔": "ji", "爾": "ji", "儿": "ji", "兒": "ji", "耳": "ji",
        "发": "faat", "發": "faat", "法": "faat", "范": "faan", "凡": "faan",
        "方": "fong", "芳": "fong", "放": "fong",
        "飞": "fei", "飛": "fei", "非": "fei", "菲": "fei", "芬": "fan",
        "凤": "fung", "鳳": "fung", "风": "fung", "風": "fung", "丰": "fung", "豐": "fung",
        "峰": "fung", "枫": "fung", "楓": "fung", "冯": "fung", "馮": "fung",
        "富": "fu", "福": "fuk", "伏": "fuk",
        "甘": "gam", "刚": "gong", "剛": "gong", "钢": "gong", "鋼": "gong", "港": "gong",
        "高": "gou", "格": "gaak", "葛": "got", "耿": "gang",
        "公": "gung", "功": "gung", "龚": "gung", "龔": "gung", "恭": "gung",
        "谷": "guk", "顾": "gu", "顧": "gu", "古": "gu",
        "光": "gwong", "广": "gwong", "廣": "gwong", "桂": "gwai", "贵": "gwai", "貴": "gwai",
        "国": "gwok", "國": "gwok", "郭": "gwok",
        "海": "hoi", "韩": "hon", "韓": "hon", "汉": "hon", "漢": "hon", "寒": "hon", "含": "ham",
        "杭": "hong", "航": "hong", "浩": "hou", "昊": "hou", "皓": "hou", "豪": "hou",
        "何": "ho", "河": "ho", "贺": "ho", "賀": "ho", "合": "hap",
        "洪": "hung", "宏": "wang", "红": "hung", "紅": "hung", "鸿": "hung", "鴻": "hung",
        "侯": "hau", "后": "hau", "胡": "wu", "湖": "wu", "虎": "fu",
        "华": "waa", "華": "waa", "花": "faa", "欢": "fun", "歡": "fun",
        "环": "waan", "環": "waan", "黄": "wong", "黃": "wong", "皇": "wong",
        "惠": "wai", "慧": "wai", "辉": "fai", "輝": "fai",
        "季": "gwai", "吉": "gat", "基": "gei", "纪": "gei", "紀": "gei",
        "嘉": "gaa", "家": "gaa", "佳": "gaai", "贾": "gaa", "賈": "gaa",
        "健": "gin", "建": "gin", "剑": "gim", "劍": "gim", "坚": "gin", "堅": "gin", "简": "gaan", "簡": "gaan",
        "江": "gong", "蒋": "zoeng", "蔣": "zoeng", "姜": "goeng", "将": "zoeng", "將": "zoeng",
        "杰": "git", "傑": "git", "捷": "zit", "洁": "git", "潔": "git",
        "金": "gam", "锦": "gam", "錦": "gam", "进": "zeon", "進": "zeon", "近": "gan",
        "晶": "zing", "京": "ging", "静": "zing", "靜": "zing", "精": "zing", "敬": "ging",
        "九": "gau", "久": "gau", "娟": "gyun",
        "俊": "zeon", "军": "gwan", "軍": "gwan", "君": "gwan",
        "凯": "hoi", "凱": "hoi", "楷": "kaai", "康": "hong",
        "克": "hak", "可": "ho", "科": "fo", "孔": "hung", "坤": "kwan", "昆": "kwan",
        "赖": "laai", "賴": "laai", "来": "loi", "來": "loi",
        "兰": "laan", "蘭": "laan", "蓝": "laam", "藍": "laam",
        "朗": "long", "老": "lou", "雷": "leoi", "磊": "leoi", "蕾": "leoi",
        "李": "lei", "力": "lik", "利": "lei", "立": "laap", "丽": "lai", "麗": "lai",
        "礼": "lai", "禮": "lai", "黎": "lai", "里": "lei", "莉": "lei",
        "莲": "lin", "蓮": "lin", "联": "lyun", "聯": "lyun",
        "梁": "loeng", "良": "loeng", "亮": "loeng", "廖": "liu",
        "林": "lam", "琳": "lam", "临": "lam", "臨": "lam",
        "灵": "ling", "靈": "ling", "玲": "ling", "凌": "ling", "令": "ling",
        "刘": "lau", "劉": "lau", "柳": "lau", "留": "lau", "流": "lau",
        "龙": "lung", "龍": "lung", "隆": "lung",
        "陆": "luk", "陸": "luk", "鲁": "lou", "魯": "lou", "卢": "lou", "盧": "lou",
        "路": "lou", "露": "lou", "罗": "lo", "羅": "lo", "骆": "lok", "駱": "lok",
        "马": "maa", "馬": "maa", "满": "mun", "滿": "mun", "曼": "maan",
        "毛": "mou", "茂": "mau", "美": "mei", "妹": "mui", "梅": "mui",
        "梦": "mung", "夢": "mung", "孟": "maang", "蒙": "mung",
        "棉": "min", "苗": "miu", "妙": "miu", "敏": "man", "民": "man",
        "明": "ming", "鸣": "ming", "鳴": "ming", "铭": "ming", "銘": "ming",
        "木": "muk", "牧": "muk", "穆": "muk",
        "那": "naa", "纳": "naap", "納": "naap", "南": "naam", "男": "naam",
        "倪": "ngai", "妮": "nei", "年": "nin", "宁": "ning", "寧": "ning",
        "农": "nung", "農": "nung", "诺": "nok", "諾": "nok",
        "欧": "au", "歐": "au",
        "潘": "pun", "盼": "paan", "鹏": "paang", "鵬": "paang", "彭": "paang", "朋": "pang",
        "平": "ping", "萍": "ping", "朴": "pok", "蒲": "pou",
        "琪": "kei", "奇": "kei", "齐": "cai", "齊": "cai", "启": "kai", "啟": "kai",
        "钱": "cin", "錢": "cin", "谦": "him", "謙": "him", "前": "cin", "千": "cin",
        "强": "koeng", "強": "koeng", "乔": "kiu", "喬": "kiu", "桥": "kiu", "橋": "kiu", "侨": "kiu", "僑": "kiu",
        "琴": "kam", "秦": "ceon", "勤": "kan", "钦": "jam", "欽": "jam",
        "清": "cing", "青": "cing", "庆": "hing", "慶": "hing", "情": "cing", "晴": "cing",
        "琼": "king", "瓊": "king", "秋": "cau", "邱": "jau", "丘": "jau",
        "全": "cyun", "权": "kyun", "權": "kyun", "泉": "cyun",
        "任": "jam", "仁": "jan", "人": "jan",
        "荣": "wing", "榮": "wing", "融": "jung",
        "如": "jyu", "儒": "jyu", "瑞": "seoi", "锐": "jeoi", "銳": "jeoi", "睿": "jeoi",
        "润": "jeon", "潤": "jeon",
        "赛": "coi", "賽": "coi", "邵": "siu", "绍": "siu", "紹": "siu",
        "沈": "sam", "深": "sam", "申": "san", "神": "san",
        "盛": "sing", "胜": "sing", "勝": "sing", "升": "sing", "声": "sing", "聲": "sing",
        "石": "sek", "时": "si", "時": "si", "史": "si", "诗": "si", "詩": "si", "师": "si", "師": "si",
        "寿": "sau", "壽": "sau", "守": "sau",
        "书": "syu", "書": "syu", "树": "syu", "樹": "syu", "淑": "suk", "舒": "syu",
        "顺": "seon", "順": "seon", "思": "si", "斯": "si", "四": "sei", "司": "si",
        "松": "cung", "宋": "sung", "素": "sou", "苏": "sou", "蘇": "sou",
        "随": "ceoi", "隨": "ceoi", "岁": "seoi", "歲": "seoi", "孙": "syun", "孫": "syun",
        "泰": "taai", "台": "toi", "太": "taai", "谭": "taam", "譚": "taam",
        "唐": "tong", "棠": "tong", "堂": "tong", "涛": "tou", "濤": "tou", "陶": "tou", "桃": "tou",
        "腾": "tang", "騰": "tang", "天": "tin", "田": "tin", "甜": "tim",
        "廷": "ting", "庭": "ting", "婷": "ting",
        "同": "tung", "童": "tung", "桐": "tung", "统": "tung", "統": "tung",
        "涂": "tou", "途": "tou", "图": "tou", "圖": "tou",
        "万": "maan", "萬": "maan", "完": "jyun", "晚": "maan",
        "王": "wong", "旺": "wong", "汪": "wong",
        "威": "wai", "卫": "wai", "衛": "wai", "微": "mei", "维": "wai", "維": "wai",
        "伟": "wai", "偉": "wai", "为": "wai", "為": "wai",
        "温": "wan", "溫": "wan", "文": "man", "闻": "man", "聞": "man",
        "翁": "jung", "武": "mou", "吴": "ng", "吳": "ng", "伍": "ng", "吾": "ng", "无": "mou", "無": "mou",
        "熙": "hei", "喜": "hei", "溪": "kai", "希": "hei", "锡": "sek", "錫": "sek",
        "夏": "haa", "霞": "haa",
        "贤": "jin", "賢": "jin", "先": "sin", "仙": "sin", "显": "hin", "顯": "hin",
        "湘": "soeng", "香": "hoeng", "翔": "coeng", "祥": "coeng", "详": "coeng", "詳": "coeng",
        "萧": "siu", "蕭": "siu", "晓": "hiu", "曉": "hiu", "小": "siu", "孝": "haau", "肖": "ciu",
        "谢": "ze", "謝": "ze", "协": "hip", "協": "hip",
        "新": "san", "心": "sam", "信": "seon", "辛": "san", "欣": "jan",
        "兴": "hing", "興": "hing", "星": "sing", "邢": "jing", "幸": "hang",
        "雄": "hung", "熊": "hung", "秀": "sau", "修": "sau",
        "旭": "juk", "徐": "ceoi", "序": "zeoi", "许": "heoi", "許": "heoi",
        "宣": "syun", "玄": "jyun", "旋": "syun", "雪": "syut", "薛": "sit",
        "勋": "fan", "勳": "fan", "迅": "seon",
        "雅": "ngaa", "亚": "aa", "亞": "aa",
        "燕": "jin", "颜": "ngaan", "顏": "ngaan", "严": "jim", "嚴": "jim", "妍": "jin", "艳": "jim", "艷": "jim",
        "杨": "joeng", "楊": "joeng", "阳": "joeng", "陽": "joeng",
        "耀": "jiu", "姚": "jiu", "遥": "jiu", "遙": "jiu", "叶": "jip", "葉": "jip",
        "义": "ji", "義": "ji", "一": "jat", "艺": "ngai", "藝": "ngai", "易": "ji", "意": "ji",
        "仪": "ji", "儀": "ji", "宜": "ji", "逸": "jat",
        "因": "jan", "银": "ngan", "銀": "ngan", "尹": "wan",
        "英": "jing", "鹰": "jing", "鷹": "jing", "盈": "jing", "颖": "wing", "穎": "wing", "迎": "jing",
        "勇": "jung", "永": "wing", "用": "jung", "雍": "jung",
        "友": "jau", "有": "jau", "由": "jau", "游": "jau", "悠": "jau", "优": "jau", "優": "jau", "尤": "jau",
        "雨": "jyu", "玉": "juk", "宇": "jyu", "裕": "jyu", "育": "juk",
        "余": "jyu", "语": "jyu", "語": "jyu",
        "元": "jyun", "原": "jyun", "园": "jyun", "園": "jyun", "缘": "jyun", "緣": "jyun",
        "远": "jyun", "遠": "jyun", "源": "jyun", "苑": "jyun", "袁": "jyun",
        "悦": "jyut", "月": "jyut", "越": "jyut", "岳": "ngok",
        "云": "wan", "雲": "wan", "运": "wan", "運": "wan", "韵": "wan", "韻": "wan",
        "赞": "zaan", "贊": "zaan", "早": "zou", "造": "zou", "泽": "zaak", "澤": "zaak",
        "曾": "cang", "战": "zin", "戰": "zin", "展": "zin",
        "张": "zoeng", "張": "zoeng", "章": "zoeng", "樟": "zoeng",
        "赵": "ziu", "趙": "ziu", "照": "ziu", "召": "ziu",
        "哲": "zit", "浙": "zit", "珍": "zan", "振": "zan", "甄": "jan", "真": "zan", "贞": "zing", "貞": "zing",
        "政": "zing", "郑": "zeng", "鄭": "zeng", "正": "zing",
        "志": "zi", "智": "zi", "之": "zi", "致": "zi", "知": "zi",
        "钟": "zung", "鍾": "zung", "鐘": "zung", "中": "zung", "忠": "zung", "众": "zung", "眾": "zung",
        "周": "zau", "洲": "zau", "州": "zau",
        "朱": "zyu", "珠": "zyu", "竹": "zuk", "柱": "cyu",
        "卓": "coek", "灼": "coek", "子": "zi", "自": "zi", "紫": "zi", "资": "zi", "資": "zi",
        "宗": "zung", "综": "zung", "綜": "zung", "邹": "zau", "鄒": "zau",
        "祖": "zou", "佐": "zo", "作": "zok",
    ]

    public static func jyutping(of char: Character) -> String? {
        table[char]
    }

    public static func findMatch(name: String, in text: String) -> String? {
        let nameChars = Array(name), textChars = Array(text)
        guard !nameChars.isEmpty, textChars.count >= nameChars.count else { return nil }

        var nameJyutping = [String]()
        nameJyutping.reserveCapacity(nameChars.count)
        for c in nameChars {
            guard let p = table[c] else { return nil }
            nameJyutping.append(p)
        }

        for start in 0...(textChars.count - nameChars.count) {
            var match = true
            for j in 0..<nameChars.count {
                guard let tp = table[textChars[start + j]], tp == nameJyutping[j] else {
                    match = false
                    break
                }
            }
            if match {
                return String(textChars[start..<(start + nameChars.count)])
            }
        }
        return nil
    }
}
