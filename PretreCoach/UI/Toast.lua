-- Toasts : pile de 3 au plus, en haut au centre, jamais dans le chat. Un même texte attend son délai.
local _, ns = ...
local UI = ns.UI

local MAX, HOLD, H, GAP, SLIDE = 3, 4, 34, 6, 20
local active, pool, lastShown = {}, {}, {}

local function place(t, i, offset)
  t:ClearAllPoints()
  t:SetPoint("TOP", UIParent, "TOP", 0, -90 - (i - 1) * (H + GAP) + (offset or 0))
end

local function layout() for i, t in ipairs(active) do t.slot = i place(t, i) end end

local function release(t)
  for i, x in ipairs(active) do
    if x == t then table.remove(active, i) break end
  end
  t.token = (t.token or 0) + 1
  t:Hide()
  pool[#pool + 1] = t
  layout()
end

local function build()
  local t = UI.Panel(nil, UIParent)
  t:SetSize(320, H)
  t:SetFrameStrata("FULLSCREEN_DIALOG")
  t.text = t:CreateFontString(nil, "OVERLAY")
  pcall(t.text.SetFontObject, t.text, UI.font.text)
  t.text:SetPoint("CENTER", t, "CENTER")
  t.text:SetWidth(300)
  local a = UI.color.accent
  local bar = t:CreateTexture(nil, "ARTWORK")
  bar:SetColorTexture(a[1], a[2], a[3], 1)
  bar:SetPoint("TOPLEFT", t, "TOPLEFT")
  bar:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT")
  bar:SetWidth(3)

  -- Glissement : le cadre est ancré SLIDE plus haut, la translation le descend, puis on le pose.
  t.inAnim = t:CreateAnimationGroup()
  local mv = t.inAnim:CreateAnimation("Translation")
  mv:SetOffset(0, -SLIDE)
  mv:SetDuration(0.3)
  local fi = t.inAnim:CreateAnimation("Alpha")
  fi:SetFromAlpha(0)
  fi:SetToAlpha(1)
  fi:SetDuration(0.3)
  t.inAnim:SetScript("OnFinished", function() place(t, t.slot) end)

  t.outAnim = t:CreateAnimationGroup()
  local fo = t.outAnim:CreateAnimation("Alpha")
  fo:SetFromAlpha(1)
  fo:SetToAlpha(0)
  fo:SetDuration(0.4)
  pcall(t.outAnim.SetToFinalAlpha, t.outAnim, true)
  return t
end

-- Vrai si le toast est affiché ; faux s'il est bloqué (désactivé, doublon dans le délai, texte vide).
function ns.Toast(text, opts)
  opts = opts or {}
  if not text or text == "" then return false end
  if ns.db and ns.db.show and ns.db.show.toasts == false then return false end
  local key = opts.key or text
  local now = GetTime()
  if lastShown[key] and now - lastShown[key] < (opts.cooldown or 300) then return false end
  lastShown[key] = now

  if #active >= MAX then release(active[1]) end
  local t = table.remove(pool) or build()
  active[#active + 1] = t
  t.slot = #active
  t.token = (t.token or 0) + 1
  local mine = t.token
  t.text:SetText(text)
  t:SetScale((ns.db and ns.db.scale) or 1)
  t:SetAlpha(1)
  t:Show()
  place(t, t.slot, SLIDE)
  t.outAnim:Stop()
  t.inAnim:Play()
  ns.After(opts.duration or HOLD, function()
    if t.token ~= mine then return end
    t.outAnim:Play()
    ns.After(0.45, function() if t.token == mine then release(t) end end)
  end)
  return true
end

function UI.ToastCount() return #active end
