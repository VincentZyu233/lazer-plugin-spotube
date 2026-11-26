--[[
  Spotube 核心置信度音源打分匹配器 (Confidence Scoring Matcher)
  对齐 team-spotube/spotube 官方 RealNewPipeAudioAPI.kt 算法逻辑
--]]

local matcher = {}

--- 纯字节分词提取
function matcher.words(str)
  local list = {}
  if not str then return list end
  local len = string.len(str)
  local start_i = nil
  for i = 1, len do
    local b = string.byte(str, i)
    if b > 32 then
      if not start_i then start_i = i end
    else
      if start_i then
        table.insert(list, string.sub(str, start_i, i - 1))
        start_i = nil
      end
    end
  end
  if start_i then
    table.insert(list, string.sub(str, start_i, len))
  end
  return list
end

--- 字符串清洗与归一化（去除标点与多余空白，全转小写，避开正则缺陷）
function matcher.normalize(str)
  if not str or type(str) ~= "string" then return "" end
  local s = string.lower(str)
  local len = string.len(s)
  local out = {}
  local in_paren = 0
  for i = 1, len do
    local b = string.byte(s, i)
    if b == 40 or b == 91 then -- '(' or '['
      in_paren = in_paren + 1
    elseif b == 41 or b == 93 then -- ')' or ']'
      if in_paren > 0 then in_paren = in_paren - 1 end
    elseif in_paren == 0 then
      -- 保留字母、数字与非 ASCII 字符 (如中日文字符 b > 127)
      if (b >= 48 and b <= 57) or (b >= 97 and b <= 122) or b > 127 then
        table.insert(out, string.char(b))
      else
        table.insert(out, " ")
      end
    end
  end
  local clean = table.concat(out)
  local words = matcher.words(clean)
  return table.concat(words, " ")
end

--- 核心词提纯
function matcher.core_title(title)
  return matcher.normalize(title)
end

--- 计算音轨匹配置信度得分 (0.0 ~ 1.0)
-- @param track: Spotify 原曲信息 { title, artist, durationMs, album }
-- @param candidate: YouTube 候选曲目 { id, title, uploader, durationMs }
function matcher.score(track, candidate)
  local confidence = 0.0

  local cand_title = matcher.normalize(candidate.title or "")
  local cand_uploader = matcher.normalize(candidate.uploader or "")
  local raw_uploader = candidate.uploader or ""

  local target_title = matcher.core_title(track.title or "")
  local target_artist = matcher.normalize(track.artist or "")
  local target_duration = tonumber(track.durationMs) or 0
  local cand_duration = tonumber(candidate.durationMs) or 0

  -- 1. 标题匹配度 (+0.3)
  if string.len(target_title) > 0 and string.find(cand_title, target_title, 1, true) then
    confidence = confidence + 0.3
  else
    -- 分词匹配
    local words = matcher.words(target_title)
    local total_words = #words
    local matched_words = 0
    for _, word in ipairs(words) do
      if string.find(cand_title, word, 1, true) then
        matched_words = matched_words + 1
      end
    end
    if total_words > 0 and (matched_words / total_words) >= 0.75 then
      confidence = confidence + 0.25
    end
  end

  -- 2. 上传者/艺人匹配度 (+0.3)
  local is_uploader_match = false
  if string.len(target_artist) > 0 and string.len(cand_uploader) > 0 then
    if string.find(cand_uploader, target_artist, 1, true) or string.find(target_artist, cand_uploader, 1, true) then
      confidence = confidence + 0.3
      is_uploader_match = true
    end
  end

  -- 3. 时长误差判定 (+0.1 ~ +0.2)
  if target_duration > 0 and cand_duration > 0 then
    local diff_ms = math.abs(cand_duration - target_duration)
    if diff_ms <= 10000 then
      -- 误差 <= 10 秒，极高概率为官方录音室原版
      confidence = confidence + 0.2
    elseif diff_ms <= 30000 then
      -- 误差 <= 30 秒
      confidence = confidence + 0.1
    end
  end

  -- 4. 艺人名出现在视频标题中 (+0.1)
  if string.len(target_artist) > 0 and string.find(cand_title, target_artist, 1, true) then
    confidence = confidence + 0.1
  end

  -- 5. 官方 Topic 频道判定 (+0.1 优先选择)
  -- YouTube 官方生成的 "Artist - Topic" 频道为直接发行的纯音频流，音质最佳且无 MV 杂音
  local is_topic_channel = string.find(string.lower(raw_uploader), "%-%s*topic") ~= nil
  if is_topic_channel and is_uploader_match then
    confidence = confidence + 0.1
  end

  if confidence > 1.0 then
    confidence = 1.0
  end

  return confidence
end

--- 从一组候选视频中选出最佳匹配者
function matcher.find_best_match(track, candidates)
  if not candidates or #candidates == 0 then
    return nil, 0
  end

  local best_cand = nil
  local max_score = -1

  for _, cand in ipairs(candidates) do
    local s = matcher.score(track, cand)
    if s > max_score then
      max_score = s
      best_cand = cand
    end
  end

  -- 设定最低接纳门槛 0.35
  if max_score >= 0.35 then
    return best_cand, max_score
  end

  -- 若未能达到高置信度门槛，回退至首个候选或 nil
  return candidates[1], max_score
end

return matcher
