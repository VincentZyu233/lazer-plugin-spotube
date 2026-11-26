--[[
  Spotube 核心置信度音源打分匹配器 (Confidence Scoring Matcher)
  对齐 team-spotube/spotube 官方 RealNewPipeAudioAPI.kt 算法逻辑
--]]

local matcher = {}

--- 字符串清洗与归一化（去除标点与多余空白，全转小写）
function matcher.normalize(str)
  if not str or type(str) ~= "string" then return "" end
  local s = string.lower(str)
  -- 去除常见音轨后缀括号标记，如 (feat. X), [Remastered]
  s = string.gsub(s, "%b()", " ")
  s = string.gsub(s, "%b[]", " ")
  -- 将非字母数字替换为空格
  s = string.gsub(s, "[%p%c]", " ")
  -- 合并连续空格并 trim
  s = string.gsub(s, "%s+", " ")
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
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
    local matched_words = 0
    local total_words = 0
    for word in string.gmatch(target_title, "%S+") do
      total_words = total_words + 1
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
