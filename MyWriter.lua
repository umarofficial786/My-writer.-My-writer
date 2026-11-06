require "import"
import "android.widget.*"
import "com.androlua.*"
import "android.content.Context"
import "android.os.Bundle"
import "android.view.accessibility.AccessibilityNodeInfo"
import "android.os.Vibrator"
import "android.speech.SpeechRecognizer"
import "android.speech.RecognizerIntent"
import "android.content.Intent"
import "android.net.Uri"
import "cjson"

_G.speechRecognizer=_G.speechRecognizer or nil
_G.isListening=_G.isListening or false
_G.lastTypedText=_G.lastTypedText or ""
local PREFS="ORTyping_v2026_Stable"

-- Recognition results below this confidence are treated as unclear
-- (soft/distant/noisy speech) and the person is asked to repeat. Devices
-- that report no usable score are never filtered. Raise it to be
-- stricter, lower it to be more forgiving.
local MIN_CONFIDENCE=0.4

local langs={
  "Urdu","Hindi","English","Arabic","Turkish","Spanish","French",
  "Bengali","Telugu","Punjabi","Marathi","Tamil","Gujarati","Kannada","Malayalam",
  "Russian","Chinese","Japanese","Korean","German","Italian","Portuguese","Dutch",
  "Vietnamese","Thai","Indonesian","Polish","Persian","Pashto","Sindhi",
  "Saraiki","Balochi","Kashmiri","Malay","Filipino","Greek","Hebrew",
  "Swedish","Norwegian","Danish","Finnish","Romanian","Hungarian","Czech","Slovak",
  "Bulgarian","Ukrainian","Serbian","Croatian","Albanian","Lithuanian","Latvian","Estonian",
  "Belarusian","Welsh","Irish","Maltese","Uzbek","Kazakh","Azerbaijani","Georgian",
  "Armenian","Amharic","Somali","Hausa","Igbo","Yoruba","Zulu","Swahili",
  "Nepali","Sinhala","Mongolian","Burmese","Khmer","Lao","Shona","Malagasy",
  "Uyghur","Cebuano","Tigrinya","Afrikaans","Javanese","Sundanese","Tatar",
  "Catalan","Macedonian","Slovenian","Basque","Galician","Kyrgyz","Tajik",
  "Turkmen","Dari","Wolof","Kinyarwanda","Chichewa","Xhosa","Lingala","Twi"
}

local transLangs={}
for _,l in ipairs(langs) do
  table.insert(transLangs,l)
end

local MODEL_ID="openai/gpt-4o-mini"
local writingStyles={"Exact Spoken Words","Professional"}

-- Every language uses its own standard, widely-supported Android/Google
-- speech-recognition locale (no experimental locale variants).
-- Recognizer used for "English" (Roman letters). "en-IN" copes better with
-- Urdu/Hindi words spoken in a South-Asian accent than "en-US" does. If a
-- phone does worse with it, change this one value back to "en-US".
local ENGLISH_LOCALE="en-IN"

local tagMap={
  Urdu="ur-PK",Hindi="hi-IN",English=ENGLISH_LOCALE,Arabic="ar-SA",
  Turkish="tr-TR",Spanish="es-ES",French="fr-FR",Bengali="bn-BD",Telugu="te-IN",
  Punjabi="pa-PK",Marathi="mr-IN",Tamil="ta-IN",Gujarati="gu-IN",Kannada="kn-IN",
  Malayalam="ml-IN",Russian="ru-RU",Chinese="zh-CN",Japanese="ja-JP",Korean="ko-KR",
  German="de-DE",Italian="it-IT",Portuguese="pt-PT",Dutch="nl-NL",Vietnamese="vi-VN",
  Thai="th-TH",Indonesian="id-ID",Polish="pl-PL",Persian="fa-IR",Malay="ms-MY",
  Filipino="fil-PH",Pashto="ps-AF",Sindhi="sd-PK",Saraiki="skr-PK",Balochi="bal-PK",
  Kashmiri="ks-IN",Greek="el-GR",Hebrew="he-IL",Swedish="sv-SE",Norwegian="nb-NO",
  Danish="da-DK",Finnish="fi-FI",Romanian="ro-RO",Hungarian="hu-HU",Czech="cs-CZ",
  Slovak="sk-SK",Bulgarian="bg-BG",Ukrainian="uk-UA",Serbian="sr-RS",Croatian="hr-HR",
  Albanian="sq-AL",Lithuanian="lt-LT",Latvian="lv-LV",Estonian="et-EE",Belarusian="be-BY",
  Welsh="cy-GB",Irish="ga-IE",Maltese="mt-MT",Uzbek="uz-UZ",Kazakh="kk-KZ",
  Azerbaijani="az-AZ",Georgian="ka-GE",Armenian="hy-AM",Amharic="am-ET",Somali="so-SO",
  Hausa="ha-NG",Igbo="ig-NG",Yoruba="yo-NG",Zulu="zu-ZA",Swahili="sw-KE",
  Nepali="ne-NP",Sinhala="si-LK",Mongolian="mn-MN",Burmese="my-MM",Khmer="km-KH",
  Lao="lo-LA",Shona="sn-ZW",Malagasy="mg-MG",Uyghur="ug-CN",Cebuano="ceb-PH",
  Tigrinya="ti-ET",Afrikaans="af-ZA",Javanese="jv-ID",Sundanese="su-ID",Tatar="tt-RU",
  Catalan="ca-ES",Macedonian="mk-MK",Slovenian="sl-SI",Basque="eu-ES",Galician="gl-ES",
  Kyrgyz="ky-KG",Tajik="tg-TJ",Turkmen="tk-TM",Dari="fa-AF",
  Wolof="wo-SN",Kinyarwanda="rw-RW",Chichewa="ny-MW",Xhosa="xh-ZA",
  Lingala="ln-CD",Twi="tw-GH"
}

local ctx=service
local vib=nil
pcall(function() vib=ctx.getSystemService(Context.VIBRATOR_SERVICE) end)
local prefs,ed=nil,nil
pcall(function()
  prefs=service.getSharedPreferences(PREFS,Context.MODE_PRIVATE)
  ed=prefs.edit()
end)

local function B(x) return x==true end
function toast(m) pcall(function() Toast.makeText(ctx,tostring(m),Toast.LENGTH_LONG).show() end) end

local function trimStr(s)
  if not s then return "" end
  return (tostring(s):gsub("^%s+",""):gsub("%s+$",""))
end

function loadS()
  if not prefs then return "","Exact Spoken Words","Urdu","English",true,true,true,2,false end
  local ok,a,b,c,d,e,f,g,h,i=pcall(function()
    return prefs.getString("orKey",""),
           prefs.getString("wStyle","Exact Spoken Words"),
           prefs.getString("pLang","Urdu"),
           prefs.getString("tLang","English"),
           prefs.getBoolean("aiOn",true),
           prefs.getBoolean("autoPunct",true),
           prefs.getBoolean("emojiOn",true),
           prefs.getInt("retries",2),
           prefs.getBoolean("isTrans",false)
  end)
  if ok then return a,b,c,d,e,f,g,h,i end
  return "","Exact Spoken Words","Urdu","English",true,true,true,2,false
end

function saveS(oK,wSty,pL,tL,ai,ap,emOn,ret,isTr)
  if not ed then toast("Save failed.") return end
  pcall(function()
    ed.putString("orKey",oK or "")
    ed.putString("wStyle",wSty or "Exact Spoken Words")
    ed.putString("pLang",pL or "Urdu")
    ed.putString("tLang",tL or "English")
    ed.putBoolean("aiOn",B(ai))
    ed.putBoolean("autoPunct",B(ap))
    ed.putBoolean("emojiOn",B(emOn))
    ed.putInt("retries",ret or 2)
    ed.putBoolean("isTrans",B(isTr))
    ed.apply()
  end)
end

function vibr(d) if vib then pcall(function() vib.vibrate(d or 50) end) end end

-- Proactive connectivity check, used right before any API call so a
-- missing internet connection is reported instantly instead of after a
-- failed or slow request. If the check itself cannot run on a device
-- (for example the network-state permission is not granted) it assumes
-- "connected", so it can never block a working connection.
function hasInternetConnection()
  local result=true
  pcall(function()
    local cm=ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
    if cm then
      local ni=cm.getActiveNetworkInfo()
      if ni==nil then
        result=false
      else
        local ok,connected=pcall(function() return ni.isConnected() end)
        if ok and connected~=nil then result=connected end
      end
    end
  end)
  return result
end

function findNode()
  local root=nil
  pcall(function() root=service.getRootInActiveWindow() end)
  if not root then return nil end
  local foc=nil
  pcall(function() foc=root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) end)
  if foc then
    local ok,e=pcall(function() return foc.isEditable() end)
    if ok and e then return foc end
  end
  local res=nil
  local function scan(n)
    if res or not n then return end
    local ok1,e=pcall(function() return n.isEditable() end)
    local ok2,v=pcall(function() return n.isVisibleToUser() end)
    if ok1 and ok2 and e and v then res=n return end
    local ok3,cnt=pcall(function() return n.getChildCount() end)
    if ok3 and cnt and cnt>0 then
      for i=0,cnt-1 do
        local ok4,ch=pcall(function() return n.getChild(i) end)
        if ok4 and ch then scan(ch) end
      end
    end
  end
  pcall(function() scan(root) end)
  return res
end

local function u8c(s)
  if not s then return {} end
  local c={}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(c,ch) end
  return c
end
local function cLen(s) return #u8c(s) end
local function c2b(s,ci)
  if not s or not ci or ci<=0 then return 0 end
  local c=u8c(s) local b=0
  for i=1,math.min(ci,#c) do b=b+#c[i] end
  return b
end

-- Applies fn to every line of text separately and puts the lines back
-- together with the same line breaks, so "new line" voice commands
-- survive every cleanup step.
local function mapLines(text,fn)
  local out={}
  for line in (text.."\n"):gmatch("(.-)\n") do
    out[#out+1]=fn(line)
  end
  return table.concat(out,"\n")
end

local function endsWithAny(text,list)
  for _,s in ipairs(list) do
    if #text>=#s and text:sub(-#s)==s then return true end
  end
  return false
end
local END_PUNCT={".","?","!",",",";",":","۔","؟","،","…","।"}

-- =====================================================================
-- Safety net for "English" (Roman letters): the phone's recognizer can
-- occasionally return a word, or a hyphenated pair like "कौन-कौन", in
-- Devanagari (Hindi) script. This converts that script to natural Roman
-- letters and leaves ordinary Roman text untouched. It runs whether AI
-- Correction is ON or OFF: whole phrases first, then whole words, then a
-- letter-by-letter fallback for anything not in the dictionary.
-- =====================================================================
local ROMAN_PHRASES={
  {"नमस्ते","namaste"},{"नमस्कार","namaskar"},
  {"आप कैसे हैं","aap kaise hain"},{"तुम कैसे हो","tum kaise ho"},
  {"क्या हाल है","kya haal hai"},{"क्या हाल चाल है","kya haal chaal hai"},
  {"मैं ठीक हूं","main theek hoon"},{"मैं ठीक हूँ","main theek hoon"},
  {"बहुत शुक्रिया","bohat shukriya"},{"बहुत धन्यवाद","bohat dhanyavaad"},
  {"जी हाँ","ji haan"},{"जी नहीं","ji nahi"},
  {"माफ़ कीजिए","maaf kijiye"},{"माफ़ करना","maaf karna"},
  {"क्या कर रहे हो","kya kar rahe ho"},{"क्या कर रही हो","kya kar rahi ho"},
  {"कोई बात नहीं","koi baat nahi"},{"बिल्कुल ठीक","bilkul theek"},
  {"अच्छी बात है","achi baat hai"},{"ठीक है ना","theek hai na"}
}

local HINDI_ROMAN_WORDS={
  -- Pronouns
  ["मैं"]="main",["तुम"]="tum",["आप"]="aap",["हम"]="hum",["वो"]="wo",
  ["वह"]="wah",["यह"]="yeh",["ये"]="ye",["इसे"]="isay",["उसे"]="usay",
  ["मुझे"]="mujhe",["तुझे"]="tujhe",["हमें"]="hamein",["तुम्हें"]="tumhein",
  ["आपको"]="aap ko",["इनको"]="in ko",["उनको"]="un ko",
  ["मेरा"]="mera",["मेरी"]="meri",["मेरे"]="meray",
  ["तुम्हारा"]="tumhara",["तुम्हारी"]="tumhari",
  ["हमारा"]="hamara",["हमारी"]="hamari",["अपना"]="apna",["अपनी"]="apni",
  -- Be-verbs / common verbs
  ["है"]="hai",["हैं"]="hain",["हूँ"]="hoon",["हूं"]="hoon",["हो"]="ho",
  ["था"]="tha",["थी"]="thi",["थे"]="thay",
  ["होगा"]="hoga",["होगी"]="hogi",["होंगे"]="hongay",
  ["कर"]="kar",["करो"]="karo",["करता"]="karta",["करती"]="karti",
  ["करते"]="kartay",["करना"]="karna",["किया"]="kiya",["किए"]="kiye",
  ["रहा"]="raha",["रही"]="rahi",["रहे"]="rahay",
  ["दिया"]="diya",["दी"]="di",["दो"]="do",["दे"]="dey",
  ["लिया"]="liya",["ली"]="li",["लो"]="lo",["ले"]="ley",
  ["गया"]="gaya",["गई"]="gai",["गए"]="gaye",
  ["जा"]="ja",["जाओ"]="jao",["जाना"]="jana",
  ["आ"]="aa",["आओ"]="aao",["आना"]="aana",["आया"]="aaya",["आई"]="aai",
  ["देख"]="dekh",["देखो"]="dekho",["देखा"]="dekha",["देखना"]="dekhna",
  ["सुन"]="sun",["सुनो"]="suno",["सुना"]="suna",["सुनना"]="sunna",
  ["बोल"]="bol",["बोलो"]="bolo",["बोला"]="bola",["बोलना"]="bolna",
  ["समझ"]="samajh",["समझा"]="samjha",["समझो"]="samjho",
  ["चाहिए"]="chahiye",["चाहता"]="chahta",["चाहती"]="chahti",
  -- Question words
  ["क्या"]="kya",["क्यों"]="kyun",["कहाँ"]="kahan",["कहां"]="kahan",
  ["कौन"]="kaun",["कैसे"]="kaise",["कैसा"]="kaisa",["कैसी"]="kaisi",
  ["कब"]="kab",["कितना"]="kitna",["कितनी"]="kitni",["कितने"]="kitne",
  ["किस"]="kis",["किसे"]="kisay",["किधर"]="kidhar",
  -- Common conjunctions / particles
  ["और"]="aur",["या"]="ya",["लेकिन"]="lekin",["मगर"]="magar",
  ["फिर"]="phir",["तो"]="to",["अगर"]="agar",["वरना"]="warna",
  ["भी"]="bhi",["नहीं"]="nahi",["ना"]="na",["हाँ"]="haan",["हां"]="haan",
  ["जी"]="ji",["ही"]="hi",["सा"]="sa",["से"]="say",["पर"]="par",
  ["के"]="kay",["की"]="ki",["का"]="ka",["को"]="ko",["ने"]="nay",
  -- Common adjectives / adverbs
  ["बहुत"]="bohat",["थोड़ा"]="thoda",["थोड़ी"]="thodi",["थोड़े"]="thoday",
  ["ज़्यादा"]="zyada",["ज्यादा"]="zyada",["कम"]="kam",["सब"]="sab",
  ["सभी"]="sabhi",["कुछ"]="kuch",["कोई"]="koi",["अच्छा"]="acha",
  ["अच्छी"]="achi",["अच्छे"]="achay",["बुरा"]="bura",["बुरी"]="buri",
  ["ठीक"]="theek",["सही"]="sahi",["ग़लत"]="ghalat",["गलत"]="ghalat",
  ["नया"]="naya",["नई"]="nai",["पुराना"]="purana",
  -- Time / place words
  ["अभी"]="abhi",["आज"]="aaj",["कल"]="kal",["परसों"]="parson",
  ["यहाँ"]="yahan",["यहां"]="yahan",["वहाँ"]="wahan",["वहां"]="wahan",
  ["सुबह"]="subah",["शाम"]="shaam",["रात"]="raat",["दिन"]="din",
  ["वक़्त"]="waqt",["वक्त"]="waqt",["समय"]="samay",
  -- Family / people
  ["दोस्त"]="dost",["भाई"]="bhai",["बहन"]="behan",["माँ"]="maa",
  ["मां"]="maa",["बाप"]="baap",["पापा"]="papa",["बेटा"]="beta",
  ["बेटी"]="beti",["घर"]="ghar",
  -- Everyday vocabulary
  ["काम"]="kaam",["बात"]="baat",["प्यार"]="pyaar",["प्यारा"]="pyaara",
  ["प्यारी"]="pyaari",["खुश"]="khush",["परेशान"]="pareshaan",
  ["पैसा"]="paisa",["पैसे"]="paisay",["खाना"]="khaana",["पानी"]="paani",
  ["मदद"]="madad",["जल्दी"]="jaldi",["धीरे"]="dheeray",
  ["शुक्रिया"]="shukriya",["धन्यवाद"]="dhanyavaad",["माफ़"]="maaf",
  ["माफ"]="maaf",["मेहरबानी"]="meherbani",["ज़रूर"]="zaroor",
  ["जरूर"]="zaroor",["बिल्कुल"]="bilkul",["शायद"]="shayad",
  ["वाकई"]="waqai",["सच"]="sach",["झूठ"]="jhoot",
  -- Numbers
  ["एक"]="ek",["तीन"]="teen",["चार"]="chaar",["पांच"]="paanch",
  ["पाँच"]="paanch",["छह"]="chhay",["सात"]="saat",["आठ"]="aath",
  ["नौ"]="nau",["दस"]="das"
}

local HINDI_ROMAN_MAP={
  ["अ"]="a",["आ"]="aa",["इ"]="i",["ई"]="ee",["उ"]="u",["ऊ"]="oo",
  ["ए"]="e",["ऐ"]="ai",["ओ"]="o",["औ"]="au",["ऑ"]="o",["ऋ"]="ri",
  ["क"]="k",["ख"]="kh",["ग"]="g",["घ"]="gh",["ङ"]="ng",
  ["च"]="ch",["छ"]="chh",["ज"]="j",["झ"]="jh",["ञ"]="ny",
  ["ट"]="t",["ठ"]="th",["ड"]="d",["ढ"]="dh",["ण"]="n",
  ["त"]="t",["थ"]="th",["द"]="d",["ध"]="dh",["न"]="n",
  ["प"]="p",["फ"]="ph",["ब"]="b",["भ"]="bh",["म"]="m",
  ["य"]="y",["र"]="r",["ल"]="l",["व"]="v",
  ["श"]="sh",["ष"]="sh",["स"]="s",["ह"]="h",["ळ"]="l",
  ["ा"]="a",["ि"]="i",["ी"]="ee",["ु"]="u",["ू"]="oo",
  ["े"]="e",["ै"]="ai",["ो"]="o",["ौ"]="au",["ं"]="n",["ँ"]="n",
  ["ॉ"]="o",["ॅ"]="e",["़"]="",
  ["्"]="",["ृ"]="ri",["ः"]="h",
  ["०"]="0",["१"]="1",["२"]="2",["३"]="3",["४"]="4",
  ["५"]="5",["६"]="6",["७"]="7",["८"]="8",["९"]="9",
  ["।"]="."
}

local DANDA="।"

local function hasDevanagari(word)
  if not word or word=="" then return false end
  local ok,res=pcall(function()
    local len=#word
    local i=1
    while i<=len do
      local b1=word:byte(i)
      if b1==224 and i+2<=len then
        local b2=word:byte(i+1)
        if b2>=164 and b2<=165 then return true end
        i=i+3
      elseif b1>=240 then i=i+4
      elseif b1>=224 then i=i+3
      elseif b1>=192 then i=i+2
      else i=i+1 end
    end
    return false
  end)
  return ok and res or false
end

local function transliterateHindiWord(w)
  local mapped=HINDI_ROMAN_WORDS[w]
  if mapped then return mapped end
  local ok,res=pcall(function()
    local chars=u8c(w)
    local out={}
    for _,ch in ipairs(chars) do
      local m=HINDI_ROMAN_MAP[ch]
      if m~=nil then table.insert(out,m)
      else table.insert(out,ch) end
    end
    return table.concat(out)
  end)
  return ok and res or w
end

-- Handles one whole token, which may end with the Hindi full stop (।)
-- or join two (often repeated) words with a hyphen, e.g. "कौन-कौन".
-- Each hyphen-separated piece is converted on its own and rejoined.
local function transliterateHindiToken(tok)
  if not tok or tok=="" then return tok end
  local tail=""
  if #tok>=#DANDA and tok:sub(-#DANDA)==DANDA then
    tok=tok:sub(1,#tok-#DANDA)
    tail="."
  end
  if tok=="" then return tail end
  if tok:find("-",1,true) then
    local ok,res=pcall(function()
      local parts={}
      for part in tok:gmatch("[^-]+") do
        table.insert(parts, hasDevanagari(part) and transliterateHindiWord(part) or part)
      end
      return table.concat(parts,"-")
    end)
    return (ok and res or tok)..tail
  end
  return transliterateHindiWord(tok)..tail
end

local function fixStrayHindiInEnglish(text,pLang)
  if not text or text=="" or pLang~="English" then return text end
  local ok0,has=pcall(hasDevanagari,text)
  if not ok0 or not has then return text end
  local ok,res=pcall(function()
    local t=text
    for _,p in ipairs(ROMAN_PHRASES) do
      t=t:gsub(p[1]:gsub("([^%w])","%%%1"),(p[2]:gsub("%%","%%%%")))
    end
    return mapLines(t,function(line)
      local out={}
      for w in line:gmatch("%S+") do
        if hasDevanagari(w) then
          local lead,core,trail=w:match("^(%p*)(.-)(%p*)$")
          core=core or w
          out[#out+1]=(lead or "")..transliterateHindiToken(core)..(trail or "")
        else
          out[#out+1]=w
        end
      end
      return table.concat(out," ")
    end)
  end)
  return ok and res or text
end

-- =====================================================================
-- Offline "English" cleanup. Only safe, meaning-free fixes: missing
-- apostrophes that recognizers drop, spacing, and capital letters. It
-- never deletes or changes words (repeated words such as "kaun kaun" or
-- "thoda thoda" are kept exactly as spoken), and it never touches words
-- that are valid English on their own (were, ill, id, lets).
-- =====================================================================
local CONTRACTION_FIXES={
  {"%f[%a]dont%f[%A]","don't"},{"%f[%a]doesnt%f[%A]","doesn't"},
  {"%f[%a]didnt%f[%A]","didn't"},{"%f[%a]cant%f[%A]","can't"},
  {"%f[%a]wont%f[%A]","won't"},
  {"%f[%a]wouldnt%f[%A]","wouldn't"},{"%f[%a]shouldnt%f[%A]","shouldn't"},
  {"%f[%a]couldnt%f[%A]","couldn't"},{"%f[%a]isnt%f[%A]","isn't"},
  {"%f[%a]arent%f[%A]","aren't"},{"%f[%a]wasnt%f[%A]","wasn't"},
  {"%f[%a]werent%f[%A]","weren't"},{"%f[%a]havent%f[%A]","haven't"},
  {"%f[%a]hasnt%f[%A]","hasn't"},{"%f[%a]hadnt%f[%A]","hadn't"},
  {"%f[%a]shant%f[%A]","shan't"},{"%f[%a]mustnt%f[%A]","mustn't"},
  {"%f[%a]im%f[%A]","I'm"},{"%f[%a]ive%f[%A]","I've"},
  {"%f[%a]youre%f[%A]","you're"},{"%f[%a]youve%f[%A]","you've"},
  {"%f[%a]youll%f[%A]","you'll"},{"%f[%a]theyre%f[%A]","they're"},
  {"%f[%a]theyve%f[%A]","they've"},{"%f[%a]weve%f[%A]","we've"},
  {"%f[%a]whats%f[%A]","what's"},{"%f[%a]thats%f[%A]","that's"}
}

local function capitalizeEnglish(text)
  if not text or text=="" then return text end
  local ok,res=pcall(function()
    text=text:gsub("%f[%a]i%f[%A]","I")
    text=text:gsub("^(%a)",function(c) return c:upper() end)
    text=text:gsub("([.!?]%s+)(%a)",function(p,c) return p..c:upper() end)
    return text
  end)
  return ok and res or text
end

local function cleanupSpacing(text)
  if not text or text=="" then return text end
  local ok,res=pcall(function()
    text=text:gsub("[ \t]+"," ")
    text=text:gsub("[ \t]+([,.!?;:])","%1")
    text=text:gsub("^[ \t]+","")
    text=text:gsub("[ \t]+$","")
    return text
  end)
  return ok and res or text
end

local function offlineEnglishCleanup(text,pLang)
  if not text or text=="" or pLang~="English" then return text end
  local ok,res=pcall(function()
    local t=text
    for _,pair in ipairs(CONTRACTION_FIXES) do
      t=t:gsub(pair[1],pair[2])
    end
    t=cleanupSpacing(t)
    t=capitalizeEnglish(t)
    return t
  end)
  return ok and res or text
end

function insertText(txt,node)
  if not txt or txt=="" then return end
  
  local tgt=node or findNode()
  if not tgt then return end
  _G.lastTypedText=tostring(txt)
  local ss,se=-1,-1
  pcall(function() ss=tgt.getTextSelectionStart() end)
  pcall(function() se=tgt.getTextSelectionEnd() end)
  local final=tostring(txt)
  local nc=cLen(final)
  pcall(function()
    if ss~=nil and ss>=0 then
      local old=""
      pcall(function() local r=tgt.getText() if r~=nil then old=tostring(r) end end)
      if not se or se<0 then se=ss end
      if ss>se then ss,se=se,ss end
      local b=old:sub(1,c2b(old,ss))
      local a=old:sub(c2b(old,se)+1)
      local ins=tostring(txt)
      if b~="" and not b:match("%s$") and not ins:match("^%s") then ins=" "..ins end
      if a~="" and not a:match("^%s") and not ins:match("%s$") then ins=ins.." " end
      final=b..ins..a nc=cLen(b)+cLen(ins)
    end
  end)
  pcall(function()
    local args=Bundle()
    args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,final)
    local ok=tgt.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,args)
    if not ok then
      tgt.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
      tgt.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,args)
    end
    local sa=Bundle()
    sa.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT,nc)
    sa.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,nc)
    tgt.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION,sa)
  end)
  vibr(80)
end

function clearField(node)
  local tgt=node or findNode()
  if not tgt then return end
  pcall(function()
    local a=Bundle()
    a.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,"")
    tgt.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,a)
  end)
  toast("Cleared.") vibr(30)
end

-- =====================================================================
-- Spoken punctuation commands ("full stop", "comma", "new line" ...).
-- Matched as WHOLE WORDS, ignoring upper/lower case, and longest
-- command first - so "comma" never changes the word "commander",
-- "period" never changes "periodic", and "full stop lagao" is not
-- half-eaten by "full stop".
-- =====================================================================
local POSES={
  {"full stop","."},{"period","."},{"comma",","},{"question mark","?"},
  {"exclamation mark","!"},{"exclamation","!"},{"exclamation point","!"},
  {"semicolon",";"},{"colon",":"},{"hyphen"," - "},{"dash"," - "},
  {"ellipsis","..."},{"dot dot dot","..."},{"open bracket"," ("},
  {"close bracket",") "},{"open paren"," ("},{"close paren",") "},
  {"new line","\n"},{"new paragraph","\n\n"},{"next line","\n"},
  {"line break","\n"},{"at the rate","@"},{"hash","#"},{"slash","/"},
  {"waqfa","."},{"sawaliya","?"},{"fajaaiya","!"},{"koma",","},
  {"nai line","\n"},{"agli line","\n"},{"naya para","\n\n"},
  {"fullstop","."},{"questionmark","?"},{"exclamationmark","!"},
  {"full stop lagaen","."},{"comma lagaen",","},{"question mark lagaen","?"},
  {"sawaliya nishaan","?"},{"full stop lagao","."},{"comma lagao",","},
  {"question mark lagao","?"},{"fulstop","."},{"fullstopp","."}
}
table.sort(POSES,function(a,b) return #a[1]>#b[1] end)

local function ciPattern(trigger)
  local out={}
  for ch in trigger:gmatch(".") do
    if ch:match("%a") then
      out[#out+1]="["..ch:lower()..ch:upper().."]"
    elseif ch:match("%w") then
      out[#out+1]=ch
    else
      out[#out+1]="%"..ch
    end
  end
  return "%f[%w]"..table.concat(out).."%f[%W]"
end

local POSE_PATTERNS={}
for _,p in ipairs(POSES) do
  POSE_PATTERNS[#POSE_PATTERNS+1]={pat=ciPattern(p[1]),rep=p[2]}
end

local function replacePoses(text)
  if not text or text=="" then return text end
  local t=text
  pcall(function()
    local changed=false
    for _,p in ipairs(POSE_PATTERNS) do
      local n
      t,n=t:gsub(p.pat,p.rep)
      if n>0 then changed=true end
    end
    -- Only when a command really fired: pull punctuation up against
    -- the previous word ("hello . how" becomes "hello. how").
    if changed then
      t=t:gsub("[ \t]+([,.!?;:])","%1")
    end
    t=t:gsub("[ \t][ \t]+"," ")
    t=t:gsub("[ \t]+\n","\n")
    t=t:gsub("\n[ \t]+","\n")
  end)
  -- Keep line breaks at the very start/end ("new line" at the end of a
  -- sentence must still work); only trim spaces and tabs.
  return (t:gsub("^[ \t]+",""):gsub("[ \t]+$",""))
end

-- =====================================================================
-- Offline smart punctuation (used whenever AI is OFF, in every
-- language). Works line by line, matches whole words only, and prefers
-- a missing mark over a wrong one.
-- =====================================================================
local function toSet(list)
  local s={}
  for _,w in ipairs(list) do s[w]=true end
  return s
end

-- Question words: Urdu, Hindi and Roman spellings. Tokens must match
-- exactly (so "کسی" or "किसान" never trigger "کس" or "किस").
local Q_WORD_SET=toSet({
  "کیا","کیوں","کہاں","کون","کیسے","کب","کتنا","کتنی","کتنے","کس","کسے",
  "کدھر","کونسا","کونسی","کونسے",
  "क्या","क्यों","कहाँ","कहां","कौन","कैसे","कब","कितना","कितनी","कितने",
  "किस","किसे","किधर","कौनसा","कौनसी","कौनसे",
  "kya","kyun","kyon","kahan","kidhar","kaun","kaunsa","kaunsi","kaunse",
  "kaise","kesay","kaisay","kesa","kaisa","kab","kub","kitna","kitni","kitne",
  "kis","kisay","kese"
})
-- English question words only count at the very start of a sentence
-- (first two words), so "I know how it works" stays a statement.
local Q_EN_WH=toSet({"what","why","where","who","whom","whose","when","how","which"})
-- Helper verbs make a question only when they OPEN the sentence and are
-- followed by a subject ("Do you...", "Is it..."), so "I have a pen" or
-- "She is my friend" stay statements.
local Q_EN_AUX=toSet({"is","are","am","do","does","did","can","could","would","should","shall","will","may","might"})
local Q_EN_AUX_NEXT=toSet({
  "you","i","we","they","he","she","it","this","that","there","these","those",
  "the","a","an","anyone","everyone","someone","my","your","his","her","our","their"
})
local Q_ES_SET=toSet({
  "qué","cómo","dónde","cuándo","quién","quiénes","cuál","cuáles",
  "cuánto","cuánta","cuántos","cuántas","adónde","que","como"
})
local EXCL_SET=toSet({
  "واہ","ماشاءاللہ","سبحاناللہ","زبردست","لاجواب","شاباش",
  "वाह","शाबाश","लाजवाब","शानदार",
  "wow","amazing","awesome","fantastic","brilliant","excellent","incredible",
  "wonderful","superb","great","perfect","hurray","yay","congrats",
  "congratulations","zabardast","lajawab","shabash","mashallah","subhanallah",
  "wah","waah"
})
local EXCL_PHRASE_SET=toSet({
  "no way","well done","good job","thank god","oh my","bahut khoob","bohat khoob",
  "subhan allah","बहुत खूब"
})

local function tokensOf(text)
  local toks={}
  for w in text:gmatch("%S+") do
    local core=w:gsub("^%p+",""):gsub("%p+$","")
    if core~="" then toks[#toks+1]=core:lower() end
  end
  return toks
end

function classifySentence(t,pLang)
  if not t or t=="" then return "statement" end
  local ok,res=pcall(function()
    if t:find("?",1,true) or t:find("؟",1,true) then return "question" end
    if t:find("!",1,true) then return "exclamation" end
    local toks=tokensOf(t)
    local n=#toks
    if n==0 then return "statement" end
    -- Exclamation: an exclamatory word opens the sentence, or the whole
    -- sentence is very short.
    if EXCL_SET[toks[1]] then return "exclamation" end
    if n>=2 and EXCL_PHRASE_SET[toks[1].." "..toks[2]] then return "exclamation" end
    if n<=4 then
      for _,w in ipairs(toks) do
        if EXCL_SET[w] then return "exclamation" end
      end
    end
    -- Question: Urdu / Hindi / Roman question words near the start.
    for i=1,math.min(n,5) do
      if Q_WORD_SET[toks[i]] then return "question" end
    end
    -- Question: English wh-word in the first two words.
    for i=1,math.min(n,2) do
      if Q_EN_WH[toks[i]] then return "question" end
    end
    -- Question: English helper verb opening the sentence + a subject.
    if n>=2 and Q_EN_AUX[toks[1]] and Q_EN_AUX_NEXT[toks[2]] then return "question" end
    if n>=2 and toks[1]=="or" and toks[2]=="what" then return "question" end
    -- Spanish question words near the start (only when Spanish is selected).
    if pLang=="Spanish" then
      for i=1,math.min(n,3) do
        if Q_ES_SET[toks[i]] then return "question" end
      end
    end
    return "statement"
  end)
  return ok and res or "statement"
end

-- A comma is added before a clear clause-joining word ("lekin", "but",
-- "however", "kyunkay" ...). Words that are also everyday non-joining
-- words (to, so, or, and, aur, then, phir, because, also ...) are left
-- alone on purpose, so the app never invents a wrong comma.
local PAUSE_SET=toSet({
  "lekin","magar","balkay","warna","chunkay","kyunkay","taakay","albata",
  "halankay","jabkay",
  "but","however","although","meanwhile","therefore","moreover","otherwise",
  "besides","anyway",
  "لیکن","مگر","بلکہ","ورنہ","چونکہ","کیونکہ","تاکہ","البتہ","حالانکہ","جبکہ",
  "लेकिन","मगर","बल्कि","वरना","चूंकि","क्योंकि","ताकि","अलबत्ता","हालांकि","जबकि"
})

local function insertNaturalPauseCommasLine(line)
  local words={}
  for w in line:gmatch("%S+") do words[#words+1]=w end
  if #words<3 then return line end
  local out={}
  for idx,w in ipairs(words) do
    local core=w:gsub("^%p+",""):gsub("%p+$","")
    local lw=core:lower()
    if idx>1 and idx<#words and (PAUSE_SET[core] or PAUSE_SET[lw]) then
      local prev=out[#out]
      local prevCore=prev:gsub("^%p+",""):gsub("%p+$",""):lower()
      if not endsWithAny(prev,END_PUNCT) and not PAUSE_SET[prevCore] then
        out[#out]=prev..","
      end
    end
    out[#out+1]=w
  end
  return table.concat(out," ")
end

-- Spanish writes an opening mark too (¿ ¡) in addition to the closing one.
local function applySpanishInvertedMarks(text,pLang,stype)
  if pLang~="Spanish" or not text or text=="" then return text end
  if stype=="question" and not text:match("^¿") then
    return "¿"..text
  elseif stype=="exclamation" and not text:match("^¡") then
    return "¡"..text
  end
  return text
end

local function punctuateLine(line,pLang)
  line=line:gsub("[ \t]+"," "):gsub("^ ",""):gsub(" $","")
  if line=="" then return line end
  line=insertNaturalPauseCommasLine(line)
  local stype=nil
  if endsWithAny(line,END_PUNCT) then
    if line:sub(-1)=="?" or endsWithAny(line,{"؟"}) then stype="question"
    elseif line:sub(-1)=="!" then stype="exclamation" end
  else
    stype=classifySentence(line,pLang)
    if stype=="question" then line=line.."?"
    elseif stype=="exclamation" then line=line.."!"
    else line=line.."." end
  end
  return applySpanishInvertedMarks(line,pLang,stype)
end

function applySmartPunct(text,pLang)
  if not text or text=="" then return text end
  local ok,res=pcall(function()
    return mapLines(text,function(line) return punctuateLine(line,pLang) end)
  end)
  return ok and res or text
end

-- =====================================================================
-- AI prompts
-- =====================================================================
-- =====================================================================
-- Emoji safety net, applied to every AI reply. With emojis ON: keep at
-- most ONE emoji per sentence and never repeat the same emoji twice in
-- the text. With emojis OFF: remove any emoji the AI added anyway, so the
-- switch is always obeyed.
-- =====================================================================
local function u8cp(ch)
  local b1=ch:byte(1)
  if not b1 then return nil end
  if b1<128 then return b1 end
  if b1>=240 and #ch>=4 then
    return ((b1-240)*262144)+((ch:byte(2)-128)*4096)+((ch:byte(3)-128)*64)+(ch:byte(4)-128)
  elseif b1>=224 and #ch>=3 then
    return ((b1-224)*4096)+((ch:byte(2)-128)*64)+(ch:byte(3)-128)
  elseif b1>=192 and #ch>=2 then
    return ((b1-192)*64)+(ch:byte(2)-128)
  end
  return b1
end

local function isEmojiBaseCp(cp)
  if not cp then return false end
  return (cp>=0x1F000 and cp<=0x1FAFF)
      or (cp>=0x2600 and cp<=0x27BF)
      or (cp>=0x2B00 and cp<=0x2BFF)
      or cp==0x231A or cp==0x231B
      or (cp>=0x23E9 and cp<=0x23F3) or (cp>=0x23F8 and cp<=0x23FA)
      or cp==0x2934 or cp==0x2935 or cp==0x3030 or cp==0x303D
      or cp==0x3297 or cp==0x3299
end

local PUNCT_MB=toSet({"۔","؟","،","।","…","“","”","‘","’","«","»","—","–","¿","¡","\194\160"})
local function isWordChar(ch)
  if #ch==1 then return ch:match("%w")~=nil end
  return not PUNCT_MB[ch]
end

local function processEmojis(text,mode)
  if not text or text=="" then return text end
  local ok,res=pcall(function()
    local chars=u8c(text)
    local n=#chars
    local cps={}
    for i=1,n do cps[i]=u8cp(chars[i]) end
    local out={}
    local seen={}
    local inSentence=false
    local sawEnd=false
    local i=1
    while i<=n do
      local cp=cps[i]
      if isEmojiBaseCp(cp) then
        local j=i
        local cluster={chars[i]}
        if cp>=0x1F1E6 and cp<=0x1F1FF and cps[i+1] and cps[i+1]>=0x1F1E6 and cps[i+1]<=0x1F1FF then
          cluster[#cluster+1]=chars[i+1]
          j=i+1
        end
        while true do
          local nx=cps[j+1]
          if nx==0xFE0F or nx==0x20E3 or (nx and nx>=0x1F3FB and nx<=0x1F3FF) then
            cluster[#cluster+1]=chars[j+1]
            j=j+1
          elseif nx==0x200D and isEmojiBaseCp(cps[j+2]) then
            cluster[#cluster+1]=chars[j+1]
            cluster[#cluster+1]=chars[j+2]
            j=j+2
          else
            break
          end
        end
        local key=table.concat(cluster)
        local norm=key:gsub("\239\184\143","")
        if mode~="strip" and not seen[norm] and not inSentence then
          out[#out+1]=key
          seen[norm]=true
          inSentence=true
        end
        i=j+1
      else
        local ch=chars[i]
        out[#out+1]=ch
        if ch=="." or ch=="?" or ch=="!" or ch=="\n" or ch=="۔" or ch=="؟" or ch=="।" then
          sawEnd=true
        elseif sawEnd and isWordChar(ch) and not ch:match("%s") then
          inSentence=false
          sawEnd=false
        end
        i=i+1
      end
    end
    local r=table.concat(out)
    r=r:gsub("[ \t][ \t]+"," ")
    r=r:gsub("[ \t]+\n","\n")
    r=r:gsub("^[ \t]+","")
    r=r:gsub("[ \t]+$","")
    return r
  end)
  return ok and res or text
end

local function applyEmojiPolicy(text,emojiOn)
  return processEmojis(text,emojiOn and "limit" or "strip")
end

-- Shared by normal typing and translation: how the AI must choose emojis.
local EMOJI_GUIDE=
  "EMOJI MATCHING RULES (very important):\n"..
  "a) Put exactly ONE emoji at the very end of each sentence, right after its punctuation mark. Never two emojis in one sentence.\n"..
  "b) First find the MAIN IDEA of that sentence (its key object, activity, place, event or feeling), then pick the single most SPECIFIC emoji for it. Prefer a specific object or activity emoji (☕ 🍽️ 🚗 📚 💼 🏠) over a face emoji. Use a face emoji only when the sentence is purely about a feeling, and then use the face that matches that exact feeling (😢 sad, 😡 angry, 😍 loving, 😂 funny, 😴 sleepy, 😌 relieved, 😟 worried, 🥵 hot, 🥶 cold).\n"..
  "c) NEVER reuse an emoji that you already used earlier in the same output. Every sentence gets a DIFFERENT emoji; if two sentences are about the same topic, choose a different but still fitting emoji for the second one.\n"..
  "d) Do NOT use generic filler emojis such as 🎯 🚀 🤔 ✅ 👍 ✨ unless the sentence is truly about that. If unsure, choose by the emotion or tone of the sentence instead.\n"..
  "e) Questions get an emoji that fits the topic of the question (not just a thinking face); greetings and thanks get a matching friendly emoji.\n"..
  "f) Hints to help you understand Roman Urdu / Hindi / Urdu words (use whichever emoji truly fits the whole sentence): chai = ☕, khana/roti/chawal/bhook = 🍽️, pani = 💧, neend/sona = 😴, baarish = 🌧️, garmi = 🥵, sardi = 🥶, gussa = 😡, rona/udaas = 😢, hansi/mazaak = 😂, pyaar/mohabbat = ❤️, paisa/rupay = 💰, kaam/office/job = 💼, padhai/school/exam = 📚, gaari/car = 🚗, bike = 🏍️, safar/flight = ✈️, ghar = 🏠, namaz/dua = 🤲, mubarak/party = 🎉, shukriya = 🙏, bimari/dawai/doctor = 🤒, dard = 🤕, phone/call = 📱, gaana/music = 🎵, cricket = 🏏, football = ⚽, shaadi = 💍, bacha/baby = 👶, subah = 🌅, raat = 🌙, dhoop = ☀️, dost = 🤝, bazaar/shopping = 🛍️."

function buildEmojiInstruction(emojiOn,isTr,professional)
  if not emojiOn then return "" end
  if isTr then
    return "\n\nEMOJI RULE: After translating, end every sentence of the translated output with its correct punctuation (. ? !) followed by ONE emoji. Add no commentary.\n"..EMOJI_GUIDE
  end
  local wordRule = professional
    and "2. Keep the meaning, every name, number and date, and the language/script exactly as spoken while polishing grammar and clarity. Never translate into another language.\n"
    or  "2. ZERO WORD ALTERATION (CRITICAL): Do NOT change user's words, names, or slang (e.g. if user says 'Sam', keep 'Sam' and NEVER change it to 'Chand' or translate it). Keep 100% exact verbatim vocabulary.\n"
  return "\n\nSTRICT MANDATORY EMOJI & PUNCTUATION RULE:\n" ..
         "1. EVERY SENTENCE ends with proper punctuation (. ? !) followed by ONE emoji that matches that sentence.\n" ..
         wordRule ..
         "3. OUTPUT FORMAT: the sentence, its punctuation mark, a space, then its emoji. Never leave a sentence without an emoji.\n\n" ..
         EMOJI_GUIDE
end

function buildPrompt(speech,isTr,tLang,pLang,wSty,emojiOn,alts)
  local professional=(wSty=="Professional")
  local emojiInstruction=buildEmojiInstruction(emojiOn,isTr,professional)
  
  if isTr then
    local toneRule=professional and "7. Write the translation in a polished, formal, professional register.\n" or ""
    return "You are a professional, highly fluent human translator specializing in "..tLang..".\n"..
      "TASK: Translate the following spoken text (spoken in "..pLang..") into "..tLang.." with excellent quality.\n"..
      ((pLang=="English") and "NOTE: The text came from a speech recognizer, and the speaker often uses Roman Urdu/Hindi. Some of those words may have been misheard as unrelated English words, so interpret them by their meaning in context.\n" or "")..
      "TRANSLATION QUALITY RULES:\n"..
      "1. Translate the COMPLETE text, however long — never summarize, shorten, skip, or leave any part untranslated.\n"..
      "2. Translate MEANING, not literally word-for-word — use natural, idiomatic phrasing that a native "..tLang.." speaker would actually use in everyday conversation.\n"..
      "3. Preserve the original tone (casual, formal, excited, questioning, etc.) and full intent of the speaker.\n"..
      "4. Keep proper nouns, names, numbers, dates, and brand names exactly as they are — do not translate or alter them.\n"..
      "5. Apply correct grammar, natural word order, and proper punctuation for "..tLang.." — commas and full stops at natural pause points, question marks for questions, exclamation marks for exclamations, and language-specific marks where "..tLang.." requires them (for example ¿ and ¡ for Spanish).\n"..
      "6. If a phrase has no direct equivalent, use the closest natural equivalent expression in "..tLang.." rather than an awkward literal translation.\n"..
      toneRule..
      "OUTPUT: only the final translated text — no notes, no explanations, no quotation marks around it, nothing else."..
      emojiInstruction.."\n\nTEXT TO TRANSLATE:\n"..speech
  end
  
  -- Translator mode is OFF: this is a formatting-only pass. No
  -- translation of any kind, whichever language is selected.
  local noTranslateRule=
    "ABSOLUTE NO-TRANSLATION RULE: Translator Mode is currently OFF, which means translation is completely disabled for this request — there is no target language here at all. The 'selected language' named below describes ONLY the script/spelling style expected for the voice input (for recognition purposes) — it is NEVER an instruction to translate into that language. Even if that name happens to be 'English', or matches some language you could translate into, you must NOT translate, convert, or rephrase the words into a different language under any circumstance. The output must stay in the exact same language the words were actually spoken in."

  local langRule=""
  if pLang=="Urdu" then
    langRule="STRICT SCRIPT RULE (recognition/output script only, NOT a translation target): The selected voice input language is Urdu. You MUST write the ENTIRE output using Urdu (Arabic) script only. If the user mixes in an English (or other foreign) word while speaking Urdu, do NOT translate that word into its Urdu meaning — just write that same word phonetically in Urdu script (transliterate the sound only), never substitute a different Urdu word of similar meaning."
  elseif pLang=="English" then
    langRule="STRICT SCRIPT RULE (recognition/output script only, NOT a translation target): The selected voice input language is English. You MUST write the ENTIRE output using ONLY the standard Roman/Latin alphabet (a-z, A-Z) — under NO circumstances output any Devanagari (Hindi) script, Arabic/Urdu script, or any other non-Latin script, even for individual words (including repeated pairs like 'kaun-kaun', 'kaise-kaise', 'kya-kya', 'thoda-thoda') that might look Hindi/Urdu in origin — spell every single word using plain Roman letters exactly as it was recognized, and keep repeated words exactly as spoken. This applies identically whether AI Correction is ON or OFF."
  elseif pLang=="Spanish" then
    langRule="STRICT SCRIPT RULE (recognition/output script only, NOT a translation target): The selected voice input language is Spanish. Keep the exact Spanish words spoken by the user. Use correct Spanish punctuation, including the inverted marks (¿ and ¡) at the start of questions and exclamations."
  else
    langRule="STRICT SCRIPT RULE (recognition/output script only, NOT a translation target): The selected voice input language is "..pLang..". Keep the exact script/spelling style of the input text as given to you — this name does not mean 'translate into "..pLang.."', it only describes what script the spoken words are already in."
  end

  local rule1
  if professional then
    rule1="1. PROFESSIONAL POLISH: Rewrite the text into clear, correct, formal, professional language — fix grammar, spelling and punctuation, remove filler words and needless repetition, and improve the flow — while preserving the exact meaning, every name, number and date, and the original language and script. Do NOT add new information and do NOT translate it.\n"
  else
    rule1="1. 100% EXACT VERBATIM WORDS: Keep the user's words completely unchanged — only fix obvious spelling, spacing and punctuation. Absolute zero synonym replacement or name altering (e.g. 'Sam' must stay 'Sam', never 'Chand'). Keep repeated words exactly as spoken. Never translate a single embedded foreign word into another language's vocabulary.\n"
  end

  local rule2 = emojiOn
    and "2. MANDATORY FULL STOPS & EMOJIS: Ensure every single sentence ends with proper punctuation and a precise emoji.\n"
    or  "2. MANDATORY PUNCTUATION, NO EMOJIS: Ensure every sentence ends with proper punctuation (. ? !) and add natural commas at pause points. Do NOT add any emoji anywhere in the output — emojis are turned OFF.\n"

  local repairRule=""
  if pLang=="English" then
    repairRule="\n\nSPEECH-RECOGNITION REPAIR (English / Roman letters): The text came from a speech recognizer and the speaker often speaks Roman Urdu or Hinglish, so some Urdu/Hindi words may have been misheard as unrelated English words. If a word makes no sense in its sentence AND sounds like a common Urdu/Hindi word that fits the meaning (for example a word that sounds like 'kya', 'hai', 'nahi', 'acha', 'theek'), replace it with that Roman Urdu word. Do this ONLY when you are confident. Never change words that already make sense."
  end
  local altBlock=""
  if alts and #alts>0 then
    altBlock="\n\nOTHER POSSIBLE TRANSCRIPTIONS of the same speech from the recognizer (reference only — use them just to repair words in the text below that were probably misheard; never add a word that appears in none of them):"
    for _,a in ipairs(alts) do altBlock=altBlock.."\n- "..a end
  end
  local role = professional
    and "You are an expert professional editor and punctuation assistant. You are NOT a translator in this mode.\n"
    or  "You are an expert strict verbatim spelling and punctuation assistant. You are NOT a translator in this mode.\n"
  
  return role..
    "YOUR CORE RULES:\n"..
    rule1..rule2..
    noTranslateRule.."\n\n"..
    langRule..repairRule..emojiInstruction..altBlock.."\n\nFORMAT THIS TEXT (do not translate it, output only the result):\n"..speech
end

function cleanR(r)
  if not r then return "" end
  r=r:gsub("^%s+",""):gsub("%s+$","")
  for _,pat in ipairs({
    "^[Cc]orrected[^:]*:%s*","^[Oo]utput[^:]*:%s*","^[Tt]ranslation[^:]*:%s*",
    "^[Hh]ere[^:]*:%s*","^[Ss]ure[,!]?%s*","^[Cc]ertainly[,!]?%s*",
    "^[Aa][Ii][^:]*:%s*","^[Oo]f course[,!]?%s*","^[Nn]ote[^:]*:%s*",
    "^[Ff]ormatted[^:]*:%s*","^[Ff]ixed[^:]*:%s*"
  }) do r=r:gsub(pat,"") end
  r=r:gsub('^"""\n?',""):gsub('\n?"""$',"")
  r=r:gsub("^```[^\n]*\n",""):gsub("\n?```$","")
  return (r:gsub("^%s+",""):gsub("%s+$",""))
end

local CLEARS={"clear","clearall","saafkaro"}
local REPEATS={"repeat","dobara","phirse"}
local function isCmd(s,cmds)
  if not s then return false end
  local ok,res=pcall(function()
    local x=s:lower():gsub("[%s%p]+","")
    for _,c in ipairs(cmds) do if x==c then return true end end
    return false
  end)
  return ok and res or false
end

-- opts: isTr, prof, temp, maxTok, maxRet
function callAPI(prompt,orK,opts,speech,node,retry)
  retry=retry or 0
  local hdrs={
    ["Content-Type"]="application/json",
    ["Authorization"]="Bearer "..orK,
    ["HTTP-Referer"]="https://frantic.resources",
    ["X-Title"]="My Writer"
  }
  local sysmsg
  if opts.isTr then
    sysmsg="You are a professional, highly fluent human translator. Translate the COMPLETE text. Output ONLY the final natural, idiomatic translation with correct grammar and punctuation for the target language."
  elseif opts.prof then
    sysmsg="You are a professional editor. Translation is fully disabled. Output ONLY the final polished text, in the same language and script as the input, with no notes or explanations."
  else
    sysmsg="You are a strict verbatim spelling and punctuation assistant. You are NOT a translator right now — translation is fully disabled. Output ONLY the final corrected text without changing the user's words, meaning, or the language/script of those words."
  end
  local body=""
  local ok=pcall(function()
    body=cjson.encode({
      model=MODEL_ID,
      messages={{role="system",content=sysmsg},{role="user",content=prompt}},
      temperature=opts.temp or 0.3,
      max_tokens=opts.maxTok or 1500
    })
  end)
  if not ok or body=="" then insertText(speech,node) return end

  local done=false
  local function finishOnce(fn)
    if done then return end
    done=true
    pcall(fn)
  end

  pcall(function()
    Http.post("https://openrouter.ai/api/v1/chat/completions",body,"application/json","UTF-8",hdrs,function(s,d)
      local okCb=pcall(function()
        -- No status / no body means the request never reached the
        -- server: a connection problem, not a server-side error.
        if s==nil or s==0 or (type(s)=="number" and s<0) or d==nil then
          finishOnce(function()
            toast("No internet connection.")
            vibr(150)
            insertText(speech,node)
          end)
          return
        end
        if s==200 then
          local ok2,res=pcall(cjson.decode,d)
          if ok2 and type(res)=="table" and res.choices and res.choices[1] and res.choices[1].message then
            local r=cleanR(tostring(res.choices[1].message.content or ""))
            r=applyEmojiPolicy(r,opts.emojiOn)
            if r=="" then r=speech end
            finishOnce(function() insertText(r,node) end)
          elseif ok2 and type(res)=="table" and res.error then
            finishOnce(function()
              toast("Error: "..tostring(res.error.message or "unknown"))
              insertText(speech,node)
            end)
          else
            finishOnce(function() insertText(speech,node) end)
          end
        elseif s==401 then
          finishOnce(function() toast("Invalid OpenRouter API Key.") insertText(speech,node) end)
        elseif s==404 then
          finishOnce(function() toast("Model error. Check key.") insertText(speech,node) end)
        elseif s==429 then
          if retry<(opts.maxRet or 2) then
            done=true
            callAPI(prompt,orK,opts,speech,node,retry+1)
          else
            finishOnce(function() insertText(speech,node) end)
          end
        else
          if retry<(opts.maxRet or 2) then
            done=true
            callAPI(prompt,orK,opts,speech,node,retry+1)
          else
            finishOnce(function() toast("Error "..tostring(s)) insertText(speech,node) end)
          end
        end
      end)
      if not okCb then
        finishOnce(function() insertText(speech,node) end)
      end
    end)
  end)

  -- Timeout safety-net: if nothing comes back, stop waiting and type
  -- the original speech so the person is never left stuck. Longer text
  -- (a long translation) is given more time before giving up.
  pcall(function()
    local waitMs=math.min(60000,15000+#speech*20)
    local Handler=luajava.bindClass("android.os.Handler")
    local Looper=luajava.bindClass("android.os.Looper")
    local h=Handler(Looper.getMainLooper())
    local r=luajava.createProxy("java.lang.Runnable",{
      run=function()
        finishOnce(function()
          toast("Slow or no internet connection.")
          vibr(150)
          insertText(speech,node)
        end)
      end
    })
    h.postDelayed(r,waitMs)
  end)
end

function processAI(speech,lang,node,alts)
  if not speech or speech=="" then return end
  if isCmd(speech,CLEARS) then clearField(node) return end
  if isCmd(speech,REPEATS) then
    if _G.lastTypedText~="" then insertText(_G.lastTypedText,node) toast("Repeated.") end
    return
  end
  
  local okP,poseResult=pcall(replacePoses,speech)
  if okP and poseResult and poseResult~="" then
    speech=poseResult
  end

  local orK,wSty,pLang,tLang,aiOn,autoPunct,emojiOn,maxRet,isTr=loadS()
  orK=trimStr(orK)
  
  if speech=="" then return end
  
  -- Stray Hindi script (English selected) -> Roman letters. Offline.
  local okH,fxH=pcall(function() return fixStrayHindiInEnglish(speech,pLang) end)
  if okH and fxH and fxH~="" then speech=fxH end
  
  -- Offline English cleanup (apostrophes, spacing, capitals). Offline.
  local okE,fxE=pcall(function() return offlineEnglishCleanup(speech,pLang) end)
  if okE and fxE and fxE~="" then speech=fxE end
  
  -- Offline punctuation applies whenever AI is OFF (nothing else would
  -- add it) and, with AI ON, whenever Translator Mode is OFF (as a
  -- pre-pass before the correction call).
  local shouldLocalPunct=B(autoPunct) and (not B(aiOn) or not B(isTr))
  if shouldLocalPunct then
    local ok,fx=pcall(function() return applySmartPunct(speech,pLang) end)
    if ok and fx and fx~="" then speech=fx end
  end
  
  -- AI switch OFF: no API call and no internet use, in any language.
  if not B(aiOn) then
    insertText(speech,node)
    return
  end
  if orK=="" then
    toast("OpenRouter API Key missing. Open AI Settings.")
    insertText(speech,node) return
  end

  -- AI ON (correction or translation) needs the internet. Checking
  -- first reports a missing connection instantly.
  local online=true
  pcall(function() online=hasInternetConnection() end)
  if not online then
    toast("No internet connection.")
    vibr(150)
    insertText(speech,node)
    return
  end

  local prompt=""
  pcall(function() prompt=buildPrompt(speech,B(isTr),tLang,pLang,wSty,B(emojiOn),alts) end)
  if not prompt or prompt=="" then insertText(speech,node) return end

  local opts={isTr=B(isTr),prof=(wSty=="Professional"),emojiOn=B(emojiOn),maxRet=maxRet or 2}
  -- Low temperature keeps "exact words" faithful; translation and
  -- professional polishing get a little more freedom.
  if opts.isTr then opts.temp=0.3
  elseif opts.prof then opts.temp=0.4
  elseif opts.emojiOn then opts.temp=0.3
  else opts.temp=0.1 end
  -- Allow enough output for long dictation (long translations
  -- included), while keeping short sentences fast.
  opts.maxTok=math.min(6000,math.max(600,#speech*3))
  callAPI(prompt,orK,opts,speech,node,0)
end

function startListen(lang,node)
  if _G.isListening then return end
  if _G.speechRecognizer then
    pcall(function() _G.speechRecognizer.destroy() end)
    _G.speechRecognizer=nil
  end

  -- Fail gracefully on devices with no speech recognition service.
  local available=true
  pcall(function() available=SpeechRecognizer.isRecognitionAvailable(ctx) end)
  if available==false then
    toast("Voice recognition isn't available on this device.")
    return
  end

  local ok,sr=pcall(function() return SpeechRecognizer.createSpeechRecognizer(ctx) end)
  if not ok or not sr then toast("Speech recognizer error.") return end
  _G.speechRecognizer=sr
  local lst=luajava.createProxy("android.speech.RecognitionListener",{
    onResults=function(b)
      _G.isListening=false
      pcall(function()
        local m=b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        -- Confidence filter. Only a real score (above 0) is used;
        -- devices that return nothing, 0 or -1 are never filtered.
        local conf=nil
        pcall(function()
          local scores=b.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
          if scores~=nil then
            local ok2,v=pcall(function() return scores[0] end)
            if ok2 and type(v)=="number" and v>0 then conf=v end
          end
        end)
        if m and m.size()>0 then
          local t=tostring(m.get(0))
          if t~="" then
            if conf==nil or conf>=MIN_CONFIDENCE then
              local alts={}
              pcall(function()
                local cnt=tonumber(tostring(m.size())) or 0
                for k=1,math.min(cnt-1,2) do
                  local a=tostring(m.get(k))
                  if a~="" and a~=t then alts[#alts+1]=a end
                end
              end)
              processAI(t,lang,node,alts)
            else
              toast("Couldn't hear that clearly, please say it again.")
              vibr(20)
            end
          end
        end
      end)
    end,
    onReadyForSpeech=function() vibr(40) end,
    onEndOfSpeech=function() _G.isListening=false end,
    onError=function(e)
      _G.isListening=false vibr(20)
      local msg="Voice error."
      pcall(function()
        local c=math.floor(tonumber(tostring(e)) or -1)
        if c==1 or c==2 then msg="No internet connection." vibr(150)
        elseif c==3 then msg="Microphone problem. Another app may be using the microphone."
        elseif c==4 or c==11 then msg="Speech service error, please try again."
        elseif c==6 then msg="No speech detected."
        elseif c==7 then msg="No match, try again."
        elseif c==8 then msg="Speech service is busy, please try again."
        elseif c==9 then msg="Microphone permission denied."
        elseif c==10 then msg="Too many requests, wait a moment and try again."
        elseif c==12 then msg="This language isn't supported by your phone's speech service."
        elseif c==13 then msg="This language needs a language pack or an internet connection." end
      end)
      toast(msg)
    end,
    onBeginningOfSpeech=function() end,onRmsChanged=function() end,
    onBufferReceived=function() end,onPartialResults=function() end,onEvent=function() end
  })
  pcall(function()
    local i=Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
    local targetLocale=tagMap[lang] or "ur-PK"
    i.putExtra(RecognizerIntent.EXTRA_LANGUAGE,targetLocale)
    i.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    i.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,3)
    -- A slightly longer silence window lets a person pause naturally
    -- while dictating long text without being cut off mid-thought.
    pcall(function() i.putExtra("android.speech.extra.SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS",1800) end)
    pcall(function() i.putExtra("android.speech.extra.SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS",1500) end)
    pcall(function() i.putExtra("android.speech.extra.SPEECH_INPUT_MINIMUM_LENGTH_MILLIS",500) end)
    _G.isListening=true
    _G.speechRecognizer.setRecognitionListener(lst)
    local okStart=pcall(function() _G.speechRecognizer.startListening(i) end)
    if not okStart then
      _G.isListening=false
      toast("Couldn't start voice recognition.")
    end
  end)
end

function gIdx(tbl,val)
  if not tbl or not val then return 0 end
  for i,v in ipairs(tbl) do if v==val then return i-1 end end
  return 0
end

function openUrl(url)
  pcall(function()
    local i=Intent(Intent.ACTION_VIEW,Uri.parse(url))
    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    ctx.startActivity(i)
  end)
end

function mkA(d)
  local a=ArrayAdapter(ctx,android.R.layout.simple_spinner_item,d)
  a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
  return a
end

function showAISettings()
  pcall(function()
    local orK=loadS()
    local lay={LinearLayout,orientation="vertical",padding="16dp",
      {TextView,text="OpenRouter API Key:"},
      {EditText,id="orEt",layout_width="fill",hint="sk-or-v1-...",inputType="text"},
      {TextView,text="Model: GPT-4o Mini",paddingTop="10dp",textSize="12sp",textColor="#888888"},
      {TextView,text="Get a key at openrouter.ai",paddingTop="4dp",textSize="11sp",textColor="#888888"}
    }
    local dlg=LuaDialog(ctx)
    dlg.setTitle("AI Settings")
    dlg.setView(loadlayout(lay))
    orEt.setText(orK or "")
    dlg.setButton("Save",function()
      pcall(function()
        local _,wSty,pL,tL,ai,ap,emOn,ret,isTr=loadS()
        local nO=""
        -- Pasted keys often carry a stray space or line break, which
        -- would make a valid key fail with "Invalid API Key".
        pcall(function() nO=trimStr(orEt.getText().toString()) end)
        saveS(nO,wSty,pL,tL,ai,ap,emOn,ret,isTr)
        dlg.dismiss() vibr(80)
        if nO=="" then
          toast("API Key cleared.")
        elseif not nO:match("^sk%-or%-") then
          toast("Saved, but this doesn't look like an OpenRouter key (it should start with sk-or-).")
        else
          toast("API Key saved!")
        end
      end)
    end)
    dlg.show()
  end)
end

function showHelp()
  pcall(function()
    local t=
      "My Writer — by Umar Jaan\n\n"..
      "Speak instead of typing — in any app, in your own language, with natural punctuation.\n\n"..
      "HOW TO USE\n"..
      "1. Tap into any text box.\n"..
      "2. Turn on this accessibility service (once).\n"..
      "3. Speak — your words are typed for you.\n\n"..
      "TYPING IN ROMAN LETTERS (Roman Urdu / Hinglish)\n"..
      "Choose “English” as the Voice Input Language to get everything in A-B-C letters.\n\n"..
      "WHAT IT CAN DO\n"..
      "• Voice typing in 99 languages, each in its own script.\n"..
      "• Smart punctuation that works with no internet and no API key.\n"..
      "• AI Correction (optional): spelling and punctuation fixes, plus a Professional writing style and smart emojis. Needs your OpenRouter API key (the account needs some credit) and internet.\n"..
      "• Translation Mode (optional): speak in one language and get typed text in another, however long. Needs AI and internet.\n"..
      "• Spoken commands: “full stop”, “comma”, “question mark”, “new line”, “new paragraph”, “clear”, “repeat”.\n\n"..
      "PRIVACY\n"..
      "With AI OFF, nothing is sent to OpenRouter and no internet is used by this app. With AI ON, your spoken text is sent to OpenRouter using your own API key. Voice recognition itself is done by your phone's speech service (usually Google).\n\n"..
      "FOR THE BEST ACCURACY\n"..
      "Speak clearly at a normal volume, close to the microphone, in a quiet place. Very soft or distant speech is the most common cause of wrong words, and results can vary slightly between phones."
    local dlg=LuaDialog(ctx)
    dlg.setTitle("About - My Writer")
    dlg.setMessage(t)
    dlg.setButton("OK",function() dlg.dismiss() end)
    dlg.show()
  end)
end

function showHelpMenu()
  pcall(function()
    local lay={LinearLayout,orientation="vertical",padding="16dp",
      {Button,id="bA",text="About and How to Use",layout_width="fill",layout_marginBottom="8dp"},
      {Button,id="bO",text="Get your OpenRouter API Key (openrouter.ai)",layout_width="fill",layout_marginBottom="8dp"},
      {Button,id="bW",text="Send Feedback on WhatsApp",layout_width="fill",layout_marginBottom="8dp"},
      {Button,id="bT",text="Join Telegram Channel",layout_width="fill",layout_marginBottom="8dp"},
      {Button,id="bY",text="Subscribe YouTube Channel",layout_width="fill",layout_marginBottom="16dp"},
      {Button,id="bC",text="Close",layout_width="fill"}
    }
    local dlg=LuaDialog(ctx)
    dlg.setTitle("Help and Feedback")
    dlg.setView(loadlayout(lay))
    bA.onClick=function() dlg.dismiss() showHelp() end
    bO.onClick=function() dlg.dismiss() openUrl("https://openrouter.ai/settings/keys") end
    bW.onClick=function()
      dlg.dismiss()
      openUrl("https://wa.me/923089162797?text=My%20Writer%20Feedback%20by%20Umar%20Jaan")
    end
    bT.onClick=function() dlg.dismiss() openUrl("https://t.me/UmarjaanPro") end
    bY.onClick=function() dlg.dismiss() openUrl("https://www.youtube.com/@UmarJaanbro") end
    bC.onClick=function() dlg.dismiss() end
    dlg.show()
  end)
end

function showSettings()
  pcall(function()
    local orK,wSty,pLang,tLang,aiOn,autoPunct,emojiOn,_,isTr=loadS()
    local lay={ScrollView,layout_width="fill",layout_height="fill",{
      LinearLayout,orientation="vertical",padding="16dp",
      {Switch,id="aiSw",text="AI Correction & Formatting",layout_width="fill"},
      {Switch,id="trSw",text="Translation Mode (Multilingual)",layout_width="fill"},
      {Switch,id="apSw",text="Smart Punctuation & Poses",layout_width="fill"},
      {Switch,id="emSw",text="Smart Emojis (Every Line/Sentence)",layout_width="fill"},
      {TextView,text="Text Writing Style:",paddingTop="8dp",textSize="13sp",textColor="#333333"},
      {Spinner,id="stySp",layout_width="fill"},
      {TextView,text="Voice Input Language:",paddingTop="8dp",textSize="13sp",textColor="#333333"},
      {Spinner,id="pSp",layout_width="fill"},
      {TextView,text="Target Translation Language:",paddingTop="8dp",textSize="13sp",textColor="#333333"},
      {Spinner,id="tSp",layout_width="fill"},
      {Button,id="aiSetBtn",text="AI Settings (API Key)",layout_width="fill",layout_marginTop="12dp"},
      {Button,id="hlpBtn",text="Help and Feedback",layout_width="fill",layout_marginTop="8dp"}
    }}
    local dlg=LuaDialog(ctx)
    dlg.setTitle("My Writer - by Umar Jaan")
    dlg.setView(loadlayout(lay))
    
    stySp.setAdapter(mkA(writingStyles))
    pSp.setAdapter(mkA(langs))
    tSp.setAdapter(mkA(transLangs))
    trSw.setChecked(B(isTr))
    aiSw.setChecked(B(aiOn))
    apSw.setChecked(B(autoPunct))
    emSw.setChecked(B(emojiOn))
    stySp.setSelection(gIdx(writingStyles,wSty))
    pSp.setSelection(gIdx(langs,pLang))
    tSp.setSelection(gIdx(transLangs,tLang))
    
    local function setDeps(on)
      trSw.setEnabled(on) stySp.setEnabled(on) emSw.setEnabled(on)
    end
    setDeps(B(aiOn))
    aiSw.setOnCheckedChangeListener(luajava.createProxy(
      "android.widget.CompoundButton$OnCheckedChangeListener",
      {onCheckedChanged=function(_,c) setDeps(c) end}
    ))
    
    aiSetBtn.onClick=function() showAISettings() end
    hlpBtn.onClick=function() dlg.dismiss() showHelpMenu() end
    
    dlg.setButton("Save Settings",function()
      pcall(function()
        local cO=loadS()
        saveS(cO,
          writingStyles[stySp.getSelectedItemPosition()+1],
          langs[pSp.getSelectedItemPosition()+1],
          transLangs[tSp.getSelectedItemPosition()+1],
          aiSw.isChecked(),
          apSw.isChecked(),
          emSw.isChecked(),
          2,
          trSw.isChecked()
        )
        dlg.dismiss() vibr(100) toast("Settings saved successfully.")
      end)
    end)
    dlg.show()
  end)
end

-- ===== MAIN ENTRY =====
local okMain,node=pcall(findNode)
if okMain and node~=nil then
  local ok3,pLangVal=pcall(function() local _,_,pLang=loadS() return pLang end)
  local pLang=(ok3 and pLangVal) or "Urdu"
  vibr(60)
  pcall(function() startListen(pLang or "Urdu",node) end)
else
  pcall(showSettings)
end
return true
