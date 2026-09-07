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

public enum PinyinHelper {
    private static let table: [Character: String] = [
        "阿": "a",  "爱": "ai", "艾": "ai", "安": "an", "昂": "ang", "傲": "ao", "奥": "ao",
        "白": "bai", "百": "bai", "拜": "bai", "柏": "bai",
        "班": "ban", "邦": "bang", "宝": "bao", "葆": "bao", "保": "bao", "包": "bao",
        "贝": "bei", "悲": "bei", "北": "bei",
        "彬": "bin", "斌": "bin", "宾": "bin", "滨": "bin",
        "冰": "bing", "兵": "bing", "炳": "bing", "丙": "bing",
        "波": "bo",  "博": "bo",  "伯": "bo",  "帛": "bo",
        "蔡": "cai", "采": "cai", "才": "cai", "彩": "cai",
        "灿": "can", "苍": "cang", "曹": "cao",
        "岑": "cen",
        "超": "chao", "朝": "chao", "晁": "chao",
        "晨": "chen", "陈": "chen", "臣": "chen", "辰": "chen", "沉": "chen",
        "程": "cheng", "成": "cheng", "诚": "cheng", "承": "cheng",
        "驰": "chi", "赤": "chi",
        "冲": "chong", "崇": "chong", "翀": "chong",
        "楚": "chu", "初": "chu",
        "春": "chun", "淳": "chun", "醇": "chun", "椿": "chun", "纯": "chun",
        "磁": "ci",  "慈": "ci",
        "聪": "cong",
        "崔": "cui", "翠": "cui",
        "达": "da",  "大": "da",
        "代": "dai", "戴": "dai", "黛": "dai",
        "丹": "dan", "淡": "dan", "旦": "dan", "单": "dan",
        "当": "dang", "党": "dang",
        "道": "dao", "导": "dao",
        "德": "de",
        "邓": "deng", "灯": "deng", "登": "deng",
        "地": "di",  "迪": "di",  "帝": "di",
        "典": "dian", "殿": "dian", "电": "dian",
        "丁": "ding", "定": "ding", "顶": "ding", "鼎": "ding",
        "东": "dong", "董": "dong", "冬": "dong",
        "度": "du",  "独": "du",  "杜": "du",  "都": "du",
        "段": "duan", "端": "duan",
        "敦": "dun",
        "多": "duo", "朵": "duo",
        "娥": "e",   "鹅": "e",
        "恩": "en",
        "尔": "er",  "儿": "er",  "耳": "er",  "贰": "er",
        "发": "fa",  "法": "fa",
        "范": "fan", "凡": "fan", "繁": "fan", "帆": "fan",
        "方": "fang", "芳": "fang", "放": "fang",
        "飞": "fei", "非": "fei", "菲": "fei", "妃": "fei", "斐": "fei",
        "芬": "fen", "粉": "fen", "奋": "fen",
        "凤": "feng", "风": "feng", "丰": "feng", "峰": "feng", "枫": "feng", "逢": "feng",
        "富": "fu",  "福": "fu",  "伏": "fu",  "甫": "fu",  "芙": "fu",  "浮": "fu",
        "甘": "gan", "干": "gan",
        "刚": "gang", "钢": "gang", "港": "gang",
        "高": "gao", "郜": "gao", "皋": "gao",
        "格": "ge",  "葛": "ge",
        "耿": "geng", "庚": "geng",
        "公": "gong", "功": "gong", "龚": "gong", "恭": "gong", "宫": "gong",
        "谷": "gu",  "顾": "gu",  "古": "gu",
        "光": "guang", "广": "guang",
        "桂": "gui", "贵": "gui", "归": "gui", "癸": "gui",
        "国": "guo", "郭": "guo", "果": "guo",
        "海": "hai",
        "韩": "han", "汉": "han", "寒": "han", "含": "han",
        "杭": "hang", "航": "hang",
        "郝": "hao", "浩": "hao", "昊": "hao", "皓": "hao", "豪": "hao", "毫": "hao",
        "何": "he",  "河": "he",  "贺": "he",  "合": "he",  "赫": "he",
        "洪": "hong", "宏": "hong", "红": "hong", "鸿": "hong", "虹": "hong", "弘": "hong",
        "侯": "hou", "后": "hou",
        "胡": "hu",  "湖": "hu",  "虎": "hu",
        "华": "hua", "花": "hua",
        "欢": "huan", "环": "huan", "焕": "huan", "煊": "huan",
        "黄": "huang", "皇": "huang", "煌": "huang",
        "惠": "hui", "慧": "hui", "晖": "hui", "辉": "hui",
        "纪": "ji",  "季": "ji",  "绩": "ji",  "基": "ji",  "吉": "ji",  "积": "ji",
        "嘉": "jia", "家": "jia", "佳": "jia", "驾": "jia", "贾": "jia",
        "健": "jian", "建": "jian", "剑": "jian", "坚": "jian", "简": "jian", "见": "jian",
        "江": "jiang", "蒋": "jiang", "姜": "jiang", "将": "jiang",
        "杰": "jie", "捷": "jie", "洁": "jie", "节": "jie", "姐": "jie",
        "金": "jin", "锦": "jin", "晋": "jin", "进": "jin", "近": "jin",
        "晶": "jing", "京": "jing", "静": "jing", "精": "jing", "镜": "jing", "敬": "jing",
        "炯": "jiong",
        "久": "jiu", "九": "jiu",
        "娟": "juan", "卷": "juan",
        "俊": "jun", "军": "jun", "君": "jun", "峻": "jun", "浚": "jun",
        "凯": "kai", "楷": "kai",
        "康": "kang", "慷": "kang",
        "克": "ke",  "可": "ke",  "科": "ke",
        "孔": "kong", "空": "kong",
        "坤": "kun", "昆": "kun", "鲲": "kun",
        "赖": "lai", "来": "lai", "莱": "lai",
        "兰": "lan", "蓝": "lan", "澜": "lan", "岚": "lan",
        "郎": "lang", "朗": "lang",
        "老": "lao", "劳": "lao",
        "雷": "lei", "磊": "lei", "蕾": "lei",
        "李": "li",  "力": "li",  "利": "li",  "立": "li",  "丽": "li",  "礼": "li",
        "黎": "li",  "里": "li",  "历": "li",  "璃": "li",  "莉": "li",  "莅": "li",
        "莲": "lian", "联": "lian", "廉": "lian", "炼": "lian",
        "梁": "liang", "良": "liang", "亮": "liang", "量": "liang", "凉": "liang",
        "廖": "liao", "寥": "liao",
        "林": "lin", "琳": "lin", "麟": "lin", "临": "lin",
        "灵": "ling", "玲": "ling", "凌": "ling", "令": "ling",
        "刘": "liu", "流": "liu", "柳": "liu", "留": "liu",
        "龙": "long", "隆": "long",
        "陆": "lu",  "鲁": "lu",  "卢": "lu",  "露": "lu",  "路": "lu",  "绿": "lu",
        "罗": "luo", "骆": "luo", "络": "luo",
        "马": "ma",  "麻": "ma",
        "满": "man", "漫": "man", "曼": "man",
        "毛": "mao", "茂": "mao",
        "美": "mei", "妹": "mei", "梅": "mei", "煤": "mei",
        "梦": "meng", "孟": "meng", "蒙": "meng",
        "弥": "mi",
        "棉": "mian", "面": "mian",
        "苗": "miao", "妙": "miao",
        "敏": "min", "民": "min", "珉": "min",
        "明": "ming", "鸣": "ming", "铭": "ming",
        "墨": "mo",  "漠": "mo",  "默": "mo",
        "木": "mu",  "牧": "mu",  "穆": "mu",  "沐": "mu",  "睦": "mu",
        "那": "na",  "纳": "na",
        "南": "nan", "男": "nan",
        "倪": "ni",  "妮": "ni",  "霓": "ni",
        "年": "nian",
        "宁": "ning", "凝": "ning",
        "农": "nong",
        "诺": "nuo",
        "欧": "ou",
        "潘": "pan", "盼": "pan",
        "鹏": "peng", "彭": "peng", "朋": "peng",
        "平": "ping", "萍": "ping",
        "朴": "pu",  "普": "pu",  "蒲": "pu",  "浦": "pu",  "溥": "pu",
        "琪": "qi",  "麒": "qi",  "奇": "qi",  "齐": "qi",  "启": "qi",  "岐": "qi",  "祁": "qi",
        "钱": "qian", "谦": "qian", "前": "qian", "千": "qian",
        "强": "qiang", "墙": "qiang",
        "乔": "qiao", "巧": "qiao", "桥": "qiao", "侨": "qiao",
        "琴": "qin", "秦": "qin", "勤": "qin", "钦": "qin", "芹": "qin",
        "清": "qing", "青": "qing", "庆": "qing", "情": "qing", "晴": "qing",
        "琼": "qiong",
        "秋": "qiu", "球": "qiu", "邱": "qiu", "裘": "qiu", "丘": "qiu",
        "曲": "qu",  "渠": "qu",  "屈": "qu",
        "全": "quan", "权": "quan", "泉": "quan",
        "任": "ren", "仁": "ren", "人": "ren",
        "荣": "rong", "熔": "rong", "融": "rong",
        "如": "ru",  "儒": "ru",  "汝": "ru",
        "瑞": "rui", "锐": "rui", "睿": "rui",
        "润": "run",
        "赛": "sai",
        "邵": "shao", "绍": "shao",
        "沈": "shen", "深": "shen", "申": "shen", "神": "shen",
        "盛": "sheng", "胜": "sheng", "升": "sheng", "声": "sheng",
        "石": "shi", "时": "shi", "史": "shi", "诗": "shi", "师": "shi",
        "寿": "shou", "守": "shou",
        "书": "shu", "树": "shu", "淑": "shu", "舒": "shu",
        "顺": "shun", "舜": "shun",
        "思": "si",  "斯": "si",  "四": "si",  "司": "si",
        "松": "song", "宋": "song", "颂": "song",
        "素": "su",  "苏": "su",
        "随": "sui", "岁": "sui", "穗": "sui",
        "孙": "sun",
        "泰": "tai", "台": "tai", "太": "tai",
        "谭": "tan", "坛": "tan",
        "唐": "tang", "棠": "tang", "堂": "tang",
        "涛": "tao", "陶": "tao", "桃": "tao",
        "腾": "teng", "滕": "teng",
        "天": "tian", "田": "tian", "甜": "tian",
        "廷": "ting", "庭": "ting", "亭": "ting", "婷": "ting",
        "同": "tong", "铜": "tong", "童": "tong", "桐": "tong", "统": "tong", "通": "tong",
        "涂": "tu",  "途": "tu",  "图": "tu",  "土": "tu",
        "娃": "wa",
        "万": "wan", "完": "wan", "晚": "wan",
        "王": "wang", "旺": "wang", "汪": "wang",
        "威": "wei", "卫": "wei", "微": "wei", "维": "wei", "伟": "wei", "为": "wei",
        "温": "wen", "文": "wen", "闻": "wen",
        "翁": "weng",
        "武": "wu",  "吴": "wu",  "伍": "wu",  "吾": "wu",  "无": "wu",
        "熙": "xi",  "喜": "xi",  "溪": "xi",  "希": "xi",  "析": "xi",  "锡": "xi",
        "夏": "xia", "霞": "xia",
        "贤": "xian", "先": "xian", "仙": "xian", "鲜": "xian", "显": "xian",
        "湘": "xiang", "香": "xiang", "翔": "xiang", "祥": "xiang", "详": "xiang",
        "萧": "xiao", "晓": "xiao", "小": "xiao", "孝": "xiao", "肖": "xiao",
        "谢": "xie", "协": "xie",
        "新": "xin", "心": "xin", "信": "xin", "辛": "xin", "欣": "xin",
        "兴": "xing", "星": "xing", "邢": "xing", "幸": "xing",
        "雄": "xiong", "熊": "xiong",
        "秀": "xiu", "修": "xiu", "绣": "xiu",
        "旭": "xu",  "徐": "xu",  "序": "xu",  "许": "xu",  "绪": "xu",
        "宣": "xuan", "玄": "xuan", "旋": "xuan", "璇": "xuan",
        "雪": "xue", "薛": "xue",
        "勋": "xun", "迅": "xun", "逊": "xun",
        "雅": "ya",  "亚": "ya",  "娅": "ya",
        "燕": "yan", "颜": "yan", "严": "yan", "妍": "yan", "岩": "yan", "艳": "yan", "延": "yan",
        "杨": "yang", "阳": "yang", "泱": "yang",
        "耀": "yao", "姚": "yao", "遥": "yao", "尧": "yao",
        "叶": "ye",  "冶": "ye",
        "义": "yi",  "一": "yi",  "艺": "yi",  "易": "yi",  "意": "yi",
        "异": "yi",  "仪": "yi",  "翼": "yi",  "逸": "yi",  "宜": "yi",  "彝": "yi",
        "因": "yin", "银": "yin", "隐": "yin", "尹": "yin",
        "英": "ying", "鹰": "ying", "盈": "ying", "颖": "ying", "迎": "ying",
        "勇": "yong", "永": "yong", "用": "yong", "雍": "yong",
        "友": "you", "有": "you", "由": "you", "游": "you", "悠": "you", "优": "you", "尤": "you",
        "雨": "yu",  "玉": "yu",  "宇": "yu",  "裕": "yu",  "育": "yu",  "誉": "yu",
        "余": "yu",  "语": "yu",  "渝": "yu",
        "元": "yuan", "原": "yuan", "园": "yuan", "缘": "yuan", "远": "yuan", "源": "yuan", "苑": "yuan", "袁": "yuan",
        "悦": "yue", "月": "yue", "越": "yue", "岳": "yue",
        "云": "yun", "运": "yun", "韵": "yun", "允": "yun",
        "赞": "zan",
        "早": "zao", "造": "zao",
        "泽": "ze",
        "曾": "zeng",
        "战": "zhan", "展": "zhan",
        "张": "zhang", "章": "zhang", "樟": "zhang",
        "赵": "zhao", "召": "zhao", "照": "zhao",
        "哲": "zhe", "浙": "zhe",
        "珍": "zhen", "振": "zhen", "甄": "zhen", "真": "zhen", "贞": "zhen",
        "政": "zheng", "郑": "zheng", "正": "zheng",
        "志": "zhi", "智": "zhi", "之": "zhi", "致": "zhi", "知": "zhi",
        "钟": "zhong", "中": "zhong", "忠": "zhong", "众": "zhong",
        "周": "zhou", "洲": "zhou", "州": "zhou",
        "朱": "zhu", "珠": "zhu", "竹": "zhu", "柱": "zhu",
        "卓": "zhuo", "灼": "zhuo",
        "子": "zi",  "自": "zi",  "紫": "zi",  "资": "zi",
        "宗": "zong", "综": "zong",
        "邹": "zou",
        "祖": "zu",  "族": "zu",
        "佐": "zuo", "作": "zuo",
    ]

    public static func pinyin(of char: Character) -> String? {
        table[char]
    }

    public static func samePronunciation(_ a: String, _ b: String) -> Bool {
        let ca = Array(a), cb = Array(b)
        guard ca.count == cb.count else { return false }
        for i in 0..<ca.count {
            guard let pa = table[ca[i]], let pb = table[cb[i]], pa == pb else { return false }
        }
        return true
    }

    public static func findPinyinMatch(name: String, in text: String) -> String? {
        let nameChars = Array(name), textChars = Array(text)
        guard !nameChars.isEmpty, textChars.count >= nameChars.count else { return nil }

        var namePinyin = [String]()
        namePinyin.reserveCapacity(nameChars.count)
        for c in nameChars {
            guard let p = table[c] else { return nil }
            namePinyin.append(p)
        }

        for start in 0...(textChars.count - nameChars.count) {
            var match = true
            for j in 0..<nameChars.count {
                guard let tp = table[textChars[start + j]], tp == namePinyin[j] else {
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
