-- FL Mixer Table Select - финальный вариант с подсветкой и линиями сендов

-- Инициализация таблицы для FL-style частиц
fx_particles = {}

-- Переменная для управления видимостью панели настроек частиц
show_particle_settings = false

-- Глобальный контекст для панели настроек частиц
particle_ctx = nil

-- Настраиваемый цвет темы для смешивания с цветами треков
local THEME_COLOR = 0x1ED4E6FF  -- FL Studio голубой цвет (можно изменить на любой другой)

-- Подключение библиотеки цветов
local script_path = debug.getinfo(1, "S").source:match("@(.*)[\\/][^\\/]*$")
local color_lib_path = script_path .. "\\Color\\track_color_utils_final_fixed.lua"

-- Проверяем существование файла библиотеки
local color_utils = nil
local file = io.open(color_lib_path, "r")
if file then
    file:close()
    color_utils = dofile(color_lib_path)
end

-- Улучшенная функция получения цвета трека с использованием библиотеки
local function get_enhanced_track_color(track_index)
    if track_index == 0 then
        return 0x404040FF -- Мастер трек (серый как в Reaper)
    end
    
    local track = reaper.GetTrack(0, track_index - 1)
    if track then
        -- Получаем цвет трека из Reaper
        local reaper_color = reaper.GetTrackColor(track)
        if reaper_color ~= 0 then
            if color_utils then
                -- Используем библиотеку для корректной конвертации
                local r, g, b = color_utils.color_to_rgb(reaper_color)
                return (r << 24) | (g << 16) | (b << 8) | 0xFF
            else
                -- Правильная конвертация как в Simple_Track_Color_Mixer
                local r = reaper_color & 0xFF
                local g = (reaper_color >> 8) & 0xFF
                local b = (reaper_color >> 16) & 0xFF
                return (r << 24) | (g << 16) | (b << 8) | 0xFF
            end
        end
    end
    
    -- Используем цвет по умолчанию (серый)
    return 0x404040FF
end

-- Функция получения контрастного цвета текста
local function get_contrasting_text_color(bg_color)
    if color_utils then
        return color_utils.get_contrasting_text_color(bg_color)
    else
        -- Простая проверка яркости
        local r = (bg_color >> 16) & 0xFF
        local g = (bg_color >> 8) & 0xFF
        local b = bg_color & 0xFF
        local brightness = (r * 299 + g * 587 + b * 114) / 1000
        return brightness > 128 and 0xFF000000 or 0xFFFFFFFF
    end
end

-- Функция осветления/затемнения цвета
local function adjust_color_brightness(color, factor)
    if color_utils then
        if factor > 0 then
            return color_utils.lighten_color(color, factor)
        else
            return color_utils.darken_color(color, -factor)
        end
    else
        -- Простое осветление/затемнение
        local r = (color >> 16) & 0xFF
        local g = (color >> 8) & 0xFF
        local b = color & 0xFF
        local a = (color >> 24) & 0xFF
        
        if factor > 0 then
            r = math.min(255, r + factor * 255)
            g = math.min(255, g + factor * 255)
            b = math.min(255, b + factor * 255)
        else
            r = math.max(0, r + factor * 255)
            g = math.max(0, g + factor * 255)
            b = math.max(0, b + factor * 255)
        end
        
        return (a << 24) | (math.floor(r) << 16) | (math.floor(g) << 8) | math.floor(b)
    end
end

-- Функция отрисовки цветной полоски трека
local function draw_track_color_strip(ctx, x, y, width, height, track_index)
    local track_color = get_enhanced_track_color(track_index)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Основная цветная полоска
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, track_color)
    
    -- Градиент для объема (если доступна библиотека)
    if color_utils then
        local lighter_color = adjust_color_brightness(track_color, 0.2)
        local darker_color = adjust_color_brightness(track_color, -0.2)
        
        -- Верхний светлый градиент
        reaper.ImGui_DrawList_AddRectFilledMultiColor(draw_list, 
            x, y, x + width, y + height/3,
            lighter_color, lighter_color, track_color, track_color)
        
        -- Нижний темный градиент
        reaper.ImGui_DrawList_AddRectFilledMultiColor(draw_list, 
            x, y + height*2/3, x + width, y + height,
            track_color, track_color, darker_color, darker_color)
    end
    
    -- Рамка
    reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + width, y + height, 0x404040FF, 0, 0, 1)
end

-- ========== ПИКСЕЛЬНАЯ СИСТЕМА ДЛЯ СПЕКТРАЛЬНОГО МЕТРА ==========

-- Глобальные переменные для пиксельной системы
local pixel_systems = {} -- Пиксельные системы для каждого трека
local last_update_times = {} -- Отдельное время обновления для каждого трека
-- Advanced spectrum animation variables (based on JSFX techniques)
local spectrum_column_levels = {} -- Хранение предыдущих уровней столбцов спектра для плавной интерполяции
local spectrum_integration_buffer = {} -- Буфер интеграции для сглаживания (как в JSFX)
local spectrum_peak_hold = {} -- Удержание пиков
local spectrum_fall_rate = {} -- Адаптивная скорость падения
local integration_time = 150  -- ms, время интеграции как в JSFX
local peak_hold_time = 500   -- ms для удержания пиков
local last_spectrum_time = 0 -- Время последнего обновления спектра

-- Таблица для хранения смещений уровня ("пуша") от столкновений частиц с планкой.
-- Используем глобальную переменную, чтобы её можно было читать/записывать в разных частях скрипта.
pixel_push_offsets = pixel_push_offsets or {}

-- Таблица для хранения позиций слайдеров (handle_y) для каждого трека
local handle_positions = {}

-- ================== ДОПОЛНИТЕЛЬНАЯ СИСТЕМА "ТУМАН И ВСПЛЕСКИ" ==================

-- Конфигурация для тумана и всплесков
-- Настройки для тумана. Увеличили количество частиц и
-- уменьшили скорости для плавного «дымового» эффекта. Всплески
-- отключены, т.к. роль вспрыгивающих пикселей выполняет
-- отдельная bounce‑система.
local FOG_CONFIG = {
    -- размер частицы в пикселях (также используется для расчёта сетки)
    particle_size = 4,
    -- скорость горизонтальной волны
    wave_speed = 0.2,
    wave_amplitude = 3.0,
    -- амплитуда вертикального смещения, усиливается уровнем аудио
    vertical_wave_amp = 10.0,
    -- базовая прозрачность частиц
    fog_alpha = 0.35,
    -- скорость подъёма частиц (доля высоты в секунду)
    rise_speed = 0.05,
    -- множитель зависимости скорости подъёма от уровня сигнала
    level_rise_mult = 0.3,
    -- всплески отключены, используется отдельная bounce‑система
    burst_rate = 0,
    burst_speed = 0,
    burst_gravity = 0,
    burst_fade = 0,
    burst_size = 3,
}

-- Системы тумана и всплесков для каждого трека
local fog_systems = {}

-- Инициализация системы тумана для трека
local function init_fog_system(track_index, meter_x, meter_y, meter_width, meter_height)
    -- Инициализируем туман только один раз на трек
    if not fog_systems[track_index] then
        local fog_particles = {}
        local size = FOG_CONFIG.particle_size or 4
        local cols = math.ceil(meter_width / size)
        local rows = math.ceil(meter_height / size)
        for row = 0, rows - 1 do
            -- relative_y: 0 = верх, 1 = низ (как используется при вычислении позиции)
            local rel = 1 - (row / math.max(1, rows - 1))
            for col = 0, cols - 1 do
                local px = meter_x + col * size + size / 2
                local phase = math.random() * 2 * math.pi
                table.insert(fog_particles, {x = px, base_x = px, relative_y = rel, phase = phase})
            end
        end
        fog_systems[track_index] = {fog = fog_particles, bursts = {}}
    end
end

-- Обновление системы тумана и всплесков
local function update_fog_system(track_index, audio_level, dt, meter_x, meter_y, meter_width, meter_height, bar_y)
    -- Ensure the fog system is initialized
    init_fog_system(track_index, meter_x, meter_y, meter_width, meter_height)
    local sys = fog_systems[track_index]
    if not sys then return end
    -- Store the current audio level so it can be used in the draw call
    sys.level = audio_level or 0
    -- Define the vertical region in which fog particles should reside. The top of the region
    -- is the bar (peak) position, or the top of the meter if no bar is provided. The bottom
    -- is the bottom of the meter.
    local region_top = bar_y or meter_y
    local region_bottom = meter_y + meter_height
    local region_height = region_bottom - region_top
    local time = reaper.time_precise() or 0
    -- Update fog particles
    for _, p in ipairs(sys.fog) do
        -- Обновляем относительную высоту, создавая эффект подъёма дыма
        local rise = (FOG_CONFIG.rise_speed + (audio_level or 0) * FOG_CONFIG.level_rise_mult) * dt
        p.relative_y = p.relative_y - rise
        -- Когда частица достигает верхней границы, переносим её в основание столбца
        while p.relative_y < 0 do
            p.relative_y = p.relative_y + 1
            p.base_x = meter_x + math.random() * meter_width
            p.phase = math.random() * 2 * math.pi
        end
        -- Вертикальное колыхание, зависящее от уровня сигнала
        local vert_amp = (audio_level or 0) * FOG_CONFIG.vertical_wave_amp
        local vertical_offset = math.sin(time * FOG_CONFIG.wave_speed * 2 + p.phase) * vert_amp
        -- Пересчитываем абсолютные координаты
        p.y = region_top + (p.relative_y or 0) * region_height + vertical_offset
        p.x = p.base_x + math.sin(time * FOG_CONFIG.wave_speed + p.phase) * FOG_CONFIG.wave_amplitude
        -- Ограничиваем частицы границами столбца
        local radius = (FOG_CONFIG.particle_size or 4) / 2
        if p.x < meter_x + radius then p.x = meter_x + radius end
        if p.x > meter_x + meter_width - radius then p.x = meter_x + meter_width - radius end
        if p.y > region_bottom - radius then p.y = region_bottom - radius end
        if p.y < region_top then p.y = region_top end
    end
    -- Update bursts (disabled by configuration)
    for i = #sys.bursts, 1, -1 do
        local b = sys.bursts[i]
        b.vy = b.vy + FOG_CONFIG.burst_gravity * dt
        b.y = b.y + b.vy * dt
        b.alpha = b.alpha - FOG_CONFIG.burst_fade * dt
        if b.alpha <= 0 or b.y > meter_y + meter_height + 5 then
            table.remove(sys.bursts, i)
        end
    end
    -- Spawn bursts proportional to audio level (currently disabled)
    local to_spawn = math.floor((audio_level or 0) * FOG_CONFIG.burst_rate * dt + 0.5)
    for i = 1, to_spawn do
        local bx = meter_x + math.random() * meter_width
        local by = region_bottom - 5
        local vy = -(audio_level * FOG_CONFIG.burst_speed + math.random() * 30)
        local b = {x = bx, y = by, vy = vy, alpha = 1.0}
        table.insert(sys.bursts, b)
    end
end

-- Отрисовка тумана и всплесков
local function draw_fog_system(ctx, x, y, track_index, meter_width, meter_height)
    local sys = fog_systems[track_index]
    if not sys then return end
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    -- Определяем текущий уровень аудио для управления яркостью
    local level = sys.level or 0
    -- Рисуем дым как маленькие квадратики LCD. Они заполняют столбик до планки.
    for _, p in ipairs(sys.fog) do
        -- frequency_factor зависит от вертикальной позиции: нижние части синее, верхние более циан
        local freq_factor = 0
        if meter_height > 0 then
            freq_factor = (p.y - y) / meter_height
            freq_factor = math.max(0.0, math.min(1.0, freq_factor))
        end
        -- Интенсивность зависит от общего уровня сигнала и может слегка уменьшаться кверху
        local intensity = level
        -- Рисуем квадрат со стороной, определяемой конфигурацией
        local size = FOG_CONFIG.particle_size or 4
        draw_lcd_pixel(dl, p.x - size/2, p.y - size/2, size, size, intensity, freq_factor)
    end
    -- Рисуем всплески (если включены) как LCD‑пиксели
    for _, b in ipairs(sys.bursts) do
        local size = FOG_CONFIG.burst_size
        local intensity = math.max(0.0, math.min(1.0, b.alpha or 0))
        local freq_factor = 0
        if meter_height > 0 then
            freq_factor = (b.y - y) / meter_height
            freq_factor = math.max(0.0, math.min(1.0, freq_factor))
        end
        draw_lcd_pixel(dl, b.x - size / 2, b.y - size / 2, size, size, intensity, freq_factor)
    end
end

-- ================== СИСТЕМА "ВСПРЫГИВАЮЩИЕ И ПАДАЮЩИЕ ПИКСЕЛИ" ==================

-- Конфигурация для системы вспрыгивающих и падающих пикселей
-- Конфигурация для системы вспрыгивающих пикселей. Значения уменьшены
-- для более медленного и плавного движения. Размер частиц увеличен
-- для лучшей заметности.
local BOUNCE_CONFIG = {
    spawn_rate = 12,        -- количество новых частиц в секунду при audio_level=1 (увеличено для большей плотности)
    init_speed = 150,       -- начальная скорость вверх (медленнее)
    gravity = 200,          -- ускорение вниз (меньше для плавного падения)
    fade = 0.6,             -- скорость затухания альфы (частицы живут дольше)
    size = 5,               -- радиус частицы (чуть больше)
    bounce_damping = 0.6    -- коэффициент затухания после отскока
}

-- Системы вспрыгивающих частиц для каждого трека
local bounce_systems = {}

-- Обновление системы вспрыгивающих и падающих пикселей
local function update_bounce_system(track_index, audio_level, dt, bar_y, meter_x, meter_y, meter_width, meter_height)
    -- Ensure a particle list exists for this track
    if not bounce_systems[track_index] then
        bounce_systems[track_index] = {}
    end
    local list = bounce_systems[track_index]

    -- Determine how many new particles to spawn based on the current audio level
    local to_spawn = math.floor((audio_level or 0) * BOUNCE_CONFIG.spawn_rate * dt + 0.5)
    for i = 1, to_spawn do
        -- Horizontal spawn position is random across the meter width
        local px = meter_x + math.random() * meter_width
        -- Spawn particles from the bottom of the meter so they travel up toward the bar
        local radius = BOUNCE_CONFIG.size or 0
        local spawn_y = meter_y + meter_height - radius - 1
        -- Initial vertical velocity is upward (negative in screen coordinates)
        local vy = -(audio_level * BOUNCE_CONFIG.init_speed + math.random() * 40)
        table.insert(list, {x = px, y = spawn_y, vy = vy, alpha = 1.0})
    end

    -- Track the maximum overshoot beyond the bar to push the level indicator
    local max_push = 0
    -- Update existing particles
    for i = #list, 1, -1 do
        local p = list[i]
        -- Apply gravity
        p.vy = p.vy + BOUNCE_CONFIG.gravity * dt
        -- Update position
        p.y = p.y + p.vy * dt
        -- Fade out alpha over time
        p.alpha = p.alpha - BOUNCE_CONFIG.fade * dt
        -- Collision with the bar: particles should not move above the bar and will bounce off
        if bar_y and p.y <= bar_y then
            -- Calculate overshoot before clamping to compute push offset
            local overshoot = bar_y - p.y
            if overshoot > max_push then
                max_push = overshoot
            end
            -- Clamp particle to the bar and invert its velocity for a bounce
            p.y = bar_y
            p.vy = -p.vy * BOUNCE_CONFIG.bounce_damping
        end
        -- Remove particles that fall below the meter or fade out completely
        if p.y > meter_y + meter_height + 5 or p.alpha <= 0 then
            table.remove(list, i)
        end
    end
    return max_push
end

-- Отрисовка вспрыгивающих и падающих пикселей
local function draw_bounce_system(ctx, track_index, meter_x, meter_y, meter_width, meter_height)
    local list = bounce_systems[track_index]
    if not list then return end
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    for _, p in ipairs(list) do
        -- Радиус круга определяется размером в конфигурации
        local radius = BOUNCE_CONFIG.size
        local intensity = math.max(0.0, math.min(1.0, p.alpha or 0))
        -- Частотный коэффициент по вертикальной позиции: нижние части → низкие частоты, верхние → высокие
        local freq_factor = 0
        if meter_height > 0 then
            freq_factor = (p.y - meter_y) / meter_height
            freq_factor = math.max(0.0, math.min(1.0, freq_factor))
        end
        -- Выбираем базовый цвет в зависимости от freq_factor (аналогично draw_lcd_pixel)
        local base_color
        if freq_factor < 0.33 then
            base_color = {r = 0, g = 180, b = 255}
        elseif freq_factor < 0.66 then
            local factor = (freq_factor - 0.33) / 0.33
            base_color = {
                r = 0 + (0 - 0) * factor,
                g = 180 + (220 - 180) * factor,
                b = 255 + (255 - 255) * factor
            }
        else
            local factor = (freq_factor - 0.66) / 0.34
            base_color = {
                r = 0 + (80 - 0) * factor,
                g = 220 + (255 - 220) * factor,
                b = 255 + (255 - 255) * factor
            }
        end
        -- Усиливаем яркость в зависимости от интенсивности
        local brightness_boost = 1.5
        local final_intensity = math.min(1.0, intensity * brightness_boost)
        local r = math.floor(base_color.r * final_intensity)
        local g = math.floor(base_color.g * final_intensity)
        local b = math.floor(base_color.b * final_intensity)
        local alpha = math.floor(255 * intensity)
        -- Собираем цвет в формате RGBA (8 бит на канал)
        local color = (r << 24) | (g << 16) | (b << 8) | alpha
        -- Рисуем заполненный круг
        reaper.ImGui_DrawList_AddCircleFilled(dl, p.x, p.y, radius, color)
    end
end

-- Advanced interpolation function (from JSFX techniques)
function exponential_smooth(current, target, rate, dt)
    local smooth_factor = math.exp(-rate * dt / 1000.0)
    return current + (target - current) * (1 - smooth_factor)
end

-- LCD Pixel rendering function with realistic LCD effect
local function draw_lcd_pixel(draw_list, x, y, width, height, intensity, frequency_factor)
    -- LCD цветовая схема как на скриншоте
    local lcd_colors = {
        -- Основные цвета для разных частот (cyan/blue тематика)
        low = {r = 0, g = 180, b = 255},      -- Голубой для низких частот
        mid = {r = 0, g = 220, b = 255},      -- Светло-голубой для средних
        high = {r = 80, g = 255, b = 255},    -- Яркий cyan для высоких
        background = {r = 5, g = 15, b = 25}, -- Темно-синий фон LCD
        border = {r = 20, g = 40, b = 60}     -- Граница пикселя
    }
    
    -- Выбираем цвет в зависимости от частоты
    local base_color
    if frequency_factor < 0.33 then
        base_color = lcd_colors.low
    elseif frequency_factor < 0.66 then
        -- Интерполяция между low и mid
        local factor = (frequency_factor - 0.33) / 0.33
        base_color = {
            r = lcd_colors.low.r + (lcd_colors.mid.r - lcd_colors.low.r) * factor,
            g = lcd_colors.low.g + (lcd_colors.mid.g - lcd_colors.low.g) * factor,
            b = lcd_colors.low.b + (lcd_colors.mid.b - lcd_colors.low.b) * factor
        }
    else
        -- Интерполяция между mid и high
        local factor = (frequency_factor - 0.66) / 0.34
        base_color = {
            r = lcd_colors.mid.r + (lcd_colors.high.r - lcd_colors.mid.r) * factor,
            g = lcd_colors.mid.g + (lcd_colors.high.g - lcd_colors.mid.g) * factor,
            b = lcd_colors.mid.b + (lcd_colors.high.b - lcd_colors.mid.b) * factor
        }
    end
    
    -- Рассчитываем финальную интенсивность (увеличена для большей яркости)
    local final_intensity = math.max(0.2, intensity * 1.5) -- Увеличена минимальная видимость и общая яркость
    final_intensity = math.min(1.0, final_intensity) -- Ограничиваем максимум
    
    -- Создаем LCD эффект с несколькими слоями
    
    -- 1. Фон пикселя (темный, но более заметный)
    local bg_alpha = math.floor(120 * final_intensity) -- Увеличено с 80
    local bg_color = (lcd_colors.background.r << 24) | (lcd_colors.background.g << 16) | 
                     (lcd_colors.background.b << 8) | bg_alpha
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, bg_color)
    
    -- 2. Граница пикселя (создает эффект сегментов LCD, ярче)
    local border_alpha = math.floor(180 * final_intensity) -- Увеличено с 120
    local border_color = (lcd_colors.border.r << 24) | (lcd_colors.border.g << 16) | 
                         (lcd_colors.border.b << 8) | border_alpha
    reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + width, y + height, border_color, 0, 0, 1)
    
    -- 3. Основной светящийся пиксель (уменьшенный для создания эффекта сегмента)
    local inner_margin = 1
    local inner_x = x + inner_margin
    local inner_y = y + inner_margin
    local inner_width = width - inner_margin * 2
    local inner_height = height - inner_margin * 2
    
    if inner_width > 0 and inner_height > 0 then
        -- Основной цвет с увеличенной интенсивностью
        local main_alpha = math.floor(255 * final_intensity)
        local brightness_boost = 1.3 -- Увеличиваем яркость цветов
        local main_color = (math.floor(base_color.r * final_intensity * brightness_boost) << 24) | 
                          (math.floor(base_color.g * final_intensity * brightness_boost) << 16) | 
                          (math.floor(base_color.b * final_intensity * brightness_boost) << 8) | main_alpha
        
        reaper.ImGui_DrawList_AddRectFilled(draw_list, inner_x, inner_y, 
                                           inner_x + inner_width, inner_y + inner_height, main_color)
        
        -- 4. Эффект свечения для ярких пикселей (порог снижен для большего свечения)
        if intensity > 0.5 then -- Снижено с 0.7
            local glow_margin = -1
            local glow_alpha = math.floor(120 * (intensity - 0.5) / 0.5) -- Увеличено с 80
            local glow_color = (math.floor(base_color.r * 1.0) << 24) | -- Увеличено с 0.8
                              (math.floor(base_color.g * 1.0) << 16) | 
                              (math.floor(base_color.b * 1.0) << 8) | glow_alpha
            
            reaper.ImGui_DrawList_AddRectFilled(draw_list, 
                                               x + glow_margin, y + glow_margin,
                                               x + width - glow_margin, y + height - glow_margin, 
                                               glow_color)
        end
        
        -- 5. Дополнительный яркий центр для очень активных пикселей (порог снижен)
        if intensity > 0.8 then -- Снижено с 0.9
            local center_margin = 2
            local center_x = x + center_margin
            local center_y = y + center_margin
            local center_width = width - center_margin * 2
            local center_height = height - center_margin * 2
            
            if center_width > 0 and center_height > 0 then
                local center_alpha = math.floor(255 * (intensity - 0.8) / 0.2) -- Увеличено с 200
                local center_color = (255 << 24) | (255 << 16) | (255 << 8) | center_alpha -- Белый центр
                
                reaper.ImGui_DrawList_AddRectFilled(draw_list, center_x, center_y,
                                                   center_x + center_width, center_y + center_height,
                                                   center_color)
            end
        end
    end
end

-- Экспортируем функцию draw_lcd_pixel в глобальную область видимости, чтобы её можно было
-- вызывать из других модулей и из отложенных функций, где локальная область видимости
-- недоступна (например, в draw_fog_system).
_G.draw_lcd_pixel = draw_lcd_pixel

-- Frequency-dependent slope compensation (like JSFX octave gain)
function apply_frequency_slope(level, freq_index, total_bands, slope_db_per_octave)
    if slope_db_per_octave == 0 then return level end
    
    local freq_ratio = freq_index / total_bands
    local octaves = math.log(freq_ratio * 20000 / 20) / math.log(2)  -- Assuming 20Hz-20kHz range
    local gain_db = octaves * slope_db_per_octave
    local gain_linear = 10 ^ (gain_db / 20)
    
    return level * gain_linear
end

-- Настройки пиксельной системы
local PIXEL_CONFIG = {
    pixel_size = 2,            -- Размер одного пикселя
    meter_width = 25,          -- Ширина метра
    meter_height = 150,        -- Высота метра
    rows = 30,                 -- Количество рядов пикселей
    cols = 8,                  -- Количество колонок пикселей
    update_rate = 120,         -- FPS для плавной анимации
    max_particles = 100,       -- Максимальное количество частиц
    glow_layers = 3,           -- Количество слоев свечения
    
    -- Физика пикселей
    gravity = 80,              -- Гравитация для падения пикселей (уменьшена для более плавного движения)
    bounce_damping = 0.7,      -- Затухание при отскоке
    push_force = 120,          -- Сила толчка при сильном сигнале (уменьшена для более плавного движения)
    settle_speed = 0.95,       -- Скорость успокоения пикселей
    
    -- Визуальные эффекты
    glow_intensity = 0.8,      -- Интенсивность свечения активных пикселей
    fade_speed = 0.98,         -- Скорость затухания неактивных пикселей
    wave_speed = 1.5,          -- Скорость волнового эффекта (уменьшена для более плавного движения)
    wave_amplitude = 3.0,      -- Амплитуда волнового движения (уменьшена)
    
    -- Дополнительные эффекты
    enable_connections = false, -- Включить соединения между пикселями
    connection_distance = 20,   -- Максимальное расстояние для соединений
    max_connections = 3,        -- Максимальное количество соединений на пиксель
    enable_sparks = false,      -- Включить искры
    spark_threshold = 0.7,      -- Порог интенсивности для искр
    enable_ellipses = false,    -- Включить эллипсы
    ellipse_threshold = 0.5,    -- Порог интенсивности для эллипсов
}

-- Цвета градиента для пикселей (cyan к blue)
local PIXEL_COLORS = {
    cyan = {r = 0, g = 255, b = 255},      -- Cyan для активных пикселей
    blue = {r = 0, g = 100, b = 255},      -- Blue для средней активности
    dark_blue = {r = 0, g = 50, b = 150},  -- Dark blue для неактивных пикселей
    background = {r = 20, g = 20, b = 20}, -- Фон метра
}

-- Функция инициализации пиксельной системы для трека
local function init_pixel_system(track_index, meter_width, meter_height)
    if not pixel_systems[track_index] then
        local system = {
            pixels = {},  -- Одномерный массив пикселей
            meter_width = meter_width or PIXEL_CONFIG.meter_width,
            meter_height = meter_height or PIXEL_CONFIG.meter_height,
            current_level = 0,
            peak_level = 0,
            peak_hold_time = 0,
        }
        
        -- Создаем начальные пиксели для визуализации
        local rows = PIXEL_CONFIG.rows
        local cols = PIXEL_CONFIG.cols
        local pixel_width = system.meter_width / cols
        local pixel_height = system.meter_height / rows
        
        for row = 1, rows do
            for col = 1, cols do
                local pixel_x = (col - 1) * pixel_width + pixel_width / 2
                local pixel_y = (row - 1) * pixel_height + pixel_height / 2
                
                local pixel = {
                    x = pixel_x,
                    y = pixel_y,
                    base_x = pixel_x,
                    base_y = pixel_y,
                    velocity_x = 0,
                    velocity_y = 0,
                    intensity = 0,
                    active = false,
                    bounce_energy = 0,
                    settle_timer = 0,
                    row = row,
                    col = col,
                    alpha = 1.0,
                    life = 1.0,
                    gravity = PIXEL_CONFIG.gravity
                }
                
                table.insert(system.pixels, pixel)
            end
        end
        
        pixel_systems[track_index] = system
    end
    
    return pixel_systems[track_index]
end

-- Функция создания пикселя (заменяет create_particle)
local function create_pixel(row, col, intensity, audio_level)
    return {
        row = row,
        col = col,
        intensity = intensity or 0,
        active = true,
        bounce_energy = (intensity or 0) * PIXEL_CONFIG.push_force,
        settle_timer = 0,
    }
end

-- Функция получения цвета пикселя
local function get_pixel_color(intensity, alpha)
    local cyan = PIXEL_COLORS.cyan
    local blue = PIXEL_COLORS.blue
    local dark_blue = PIXEL_COLORS.dark_blue
    local background = PIXEL_COLORS.background
    
    local r, g, b
    if intensity > 0.7 then
        -- Высокая интенсивность: cyan
        local factor = (intensity - 0.7) / 0.3
        r = cyan.r
        g = cyan.g
        b = cyan.b
    elseif intensity > 0.3 then
        -- Средняя интенсивность: blue к cyan
        local factor = (intensity - 0.3) / 0.4
        r = blue.r + (cyan.r - blue.r) * factor
        g = blue.g + (cyan.g - blue.g) * factor
        b = blue.b + (cyan.b - blue.b) * factor
    elseif intensity > 0.05 then
        -- Низкая интенсивность: dark_blue к blue
        local factor = (intensity - 0.05) / 0.25
        r = dark_blue.r + (blue.r - dark_blue.r) * factor
        g = dark_blue.g + (blue.g - dark_blue.g) * factor
        b = dark_blue.b + (blue.b - dark_blue.b) * factor
    else
        -- Неактивный: фон
        r = background.r
        g = background.g
        b = background.b
    end
    
    -- Применяем альфа-канал
    local final_alpha = math.floor(alpha * 255)
    return (math.floor(r) << 24) | (math.floor(g) << 16) | (math.floor(b) << 8) | final_alpha
end

-- Функция обновления пиксельной системы (заменяет UpdateFXParticlesFL)
function UpdatePixelSystemFL(track_index, level, meter_x, meter_y, meter_width, meter_height)
    -- Инициализируем систему если её нет
    local system = init_pixel_system(track_index, meter_width, meter_height)
    
    local current_time = reaper.time_precise()
    local delta_time = 1.0 / PIXEL_CONFIG.update_rate
    
    -- Преобразуем уровень в дБ
    local level_db = 20 * (math.log(math.max(0.00001, level)) / math.log(10))
    level_db = math.max(-60, math.min(12, level_db))
    local db_normalized = (level_db + 60) / 72  -- -60..+12 дБ -> 0..1
    
    -- Обновляем текущий уровень системы
    system.current_level = db_normalized
    
    -- Обновляем пик с удержанием
    if db_normalized > system.peak_level then
        system.peak_level = db_normalized
        system.peak_hold_time = current_time + 1.0  -- Удерживаем пик 1 секунду
    elseif current_time > system.peak_hold_time then
        system.peak_level = system.peak_level * 0.99  -- Медленное падение пика
    end
    
    -- Обновляем каждый пиксель в одномерном массиве
    for i, pixel in ipairs(system.pixels) do
        -- Инициализируем поля пикселя если они nil
        pixel.intensity = pixel.intensity or 0
        pixel.bounce_energy = pixel.bounce_energy or 0
        pixel.velocity_x = pixel.velocity_x or 0
        pixel.velocity_y = pixel.velocity_y or 0
        pixel.base_x = pixel.base_x or pixel.x
        pixel.base_y = pixel.base_y or pixel.y
        
        -- Обновляем интенсивность с затуханием
        pixel.intensity = pixel.intensity * PIXEL_CONFIG.fade_speed
        
        -- Усиливаем интенсивность и энергию отскока на основе аудио уровня и позиции пикселя
        local pixel_y_normalized = (pixel.y - meter_y) / meter_height
        local distance_from_bottom = 1.0 - pixel_y_normalized
        
        if db_normalized > distance_from_bottom * 0.8 then
            pixel.intensity = math.min(1.0, pixel.intensity + db_normalized * delta_time * 3)
            pixel.bounce_energy = pixel.bounce_energy + db_normalized * PIXEL_CONFIG.push_force * delta_time
        end
        
        -- Применяем физику
        -- Гравитация
        pixel.velocity_y = pixel.velocity_y + PIXEL_CONFIG.gravity * delta_time
        
        -- Горизонтальное волновое движение
        local wave_phase = current_time * PIXEL_CONFIG.wave_speed + pixel.x * 0.01
        pixel.velocity_x = pixel.velocity_x + math.sin(wave_phase) * db_normalized * 10 * delta_time
        
        -- Обновляем позицию
        pixel.x = pixel.x + pixel.velocity_x * delta_time
        pixel.y = pixel.y + pixel.velocity_y * delta_time
        
        -- Применяем границы метра
        if pixel.x < meter_x then
            pixel.x = meter_x
            pixel.velocity_x = pixel.velocity_x * -PIXEL_CONFIG.bounce_damping
        elseif pixel.x > meter_x + meter_width then
            pixel.x = meter_x + meter_width
            pixel.velocity_x = pixel.velocity_x * -PIXEL_CONFIG.bounce_damping
        end
        
        if pixel.y < meter_y then
            pixel.y = meter_y
            pixel.velocity_y = pixel.velocity_y * -PIXEL_CONFIG.bounce_damping
        elseif pixel.y > meter_y + meter_height then
            pixel.y = meter_y + meter_height
            pixel.velocity_y = pixel.velocity_y * -PIXEL_CONFIG.bounce_damping
            pixel.bounce_energy = 0  -- Сбрасываем энергию отскока при достижении дна
        end
        
        -- Применяем демпфирование
        pixel.velocity_x = pixel.velocity_x * PIXEL_CONFIG.bounce_damping
        pixel.velocity_y = pixel.velocity_y * PIXEL_CONFIG.bounce_damping
        pixel.bounce_energy = pixel.bounce_energy * PIXEL_CONFIG.settle_speed
    end
    
    return 0
end

-- Функция создания нового пикселя с жесткими границами метра
local function create_pixel(x, y, intensity, audio_level, meter_width, meter_x, meter_y, meter_height)
    -- audio_level приходит как линейное значение амплитуды от Track_GetPeakInfo
    -- Преобразуем в дБ как в Reaper: dB = 20 * log10(amplitude)
    local level_db = 20 * (math.log(math.max(0.00001, audio_level)) / math.log(10))
    
    -- Ограничиваем диапазон
    local min_db = -60
    local max_db = 12
    level_db = math.max(min_db, math.min(max_db, level_db))
    
    -- Нормализуем дБ в диапазон 0-1 для расчета скорости
    local db_normalized = (level_db + 60) / 72  -- -60..+12 дБ -> 0..1
    
    -- Устанавливаем жесткие границы метра
    local safe_meter_width = meter_width or PIXEL_CONFIG.meter_width
    local safe_meter_x = meter_x or 0
    local safe_meter_y = meter_y or 0
    local safe_meter_height = meter_height or PIXEL_CONFIG.meter_height
    
    -- Жестко ограничиваем координаты внутри метра с отступом
    local margin = 3
    local min_x = safe_meter_x + margin
    local max_x = safe_meter_x + safe_meter_width - margin
    local min_y = safe_meter_y + margin
    local max_y = safe_meter_y + safe_meter_height - margin
    
    -- Принудительно помещаем пиксель внутри границ
    local clamped_x = math.max(min_x, math.min(max_x, x))
    local clamped_y = math.max(min_y, math.min(max_y, y))
    
    return {
        x = clamped_x,
        y = clamped_y,
        base_x = clamped_x,                      -- Базовая позиция для "живого" движения
        base_y = clamped_y,
        -- Сохраняем границы метра для жесткого ограничения движения
        meter_x = safe_meter_x,
        meter_y = safe_meter_y,
        meter_width = safe_meter_width,
        meter_height = safe_meter_height,
        min_x = min_x,
        max_x = max_x,
        min_y = min_y,
        max_y = max_y,
        velocity_y = -30 - (db_normalized * 80), -- Скорость подъема зависит от дБ уровня
        velocity_x = (math.random() - 0.5) * 20, -- Горизонтальная скорость для отскоков
        size = PIXEL_CONFIG.pixel_size + ((intensity or 0) * PIXEL_CONFIG.pixel_size),
        intensity = intensity or 0,
        bounce_energy = db_normalized * PIXEL_CONFIG.push_force,
        color = {r = 0, g = 0, b = 0}, -- Цвет будет установлен при отрисовке
        row = math.floor((clamped_y - safe_meter_y) / PIXEL_CONFIG.pixel_size),
        column = math.floor((clamped_x - safe_meter_x) / PIXEL_CONFIG.pixel_size),
        -- время жизни частицы и альфа/гравитация по умолчанию для UpdateFXParticlesFL
        life = 1.0,
        alpha = 1.0,
        gravity = PIXEL_CONFIG.gravity
    }
end

-- Сохраняем для обратной совместимости
local function create_particle(x, y, intensity, audio_level, meter_width, meter_x, meter_y, meter_height)
    return create_pixel(x, y, intensity, audio_level, meter_width, meter_x, meter_y, meter_height)
end

-- Функция получения цвета частицы с градиентом
-- Функция получения цвета пикселя в зависимости от интенсивности и прозрачности
local function get_pixel_color(intensity, alpha)
    local cyan = PIXEL_COLORS.cyan
    local blue = PIXEL_COLORS.blue
    local dark_blue = PIXEL_COLORS.dark_blue
    
    -- Интерполяция между cyan и blue в зависимости от интенсивности
    local r, g, b
    if intensity > 0.5 then
        -- Верхняя часть: cyan к blue
        local factor = (intensity - 0.5) * 2
        r = cyan.r + (blue.r - cyan.r) * factor
        g = cyan.g + (blue.g - cyan.g) * factor
        b = cyan.b + (blue.b - cyan.b) * factor
    else
        -- Нижняя часть: dark_blue к cyan
        local factor = intensity * 2
        r = dark_blue.r + (cyan.r - dark_blue.r) * factor
        g = dark_blue.g + (cyan.g - dark_blue.g) * factor
        b = dark_blue.b + (cyan.b - dark_blue.b) * factor
    end
    
    -- Применяем альфа-канал
    local final_alpha = math.floor(alpha * 255)
    return (math.floor(r) << 24) | (math.floor(g) << 16) | (math.floor(b) << 8) | final_alpha
end

-- Функция получения цвета частицы (для обратной совместимости)
local function get_particle_color(intensity, alpha)
    -- Перенаправляем на новую функцию
    return get_pixel_color(intensity, alpha)
end

-- Функция для создания градиентных пикселей
local function get_pixel_gradient_colors(intensity, alpha)
    local colors = {}
    local base_color = get_pixel_color(intensity, alpha)
    
    -- Создаем градиент от центра к краям
    colors.center = base_color
    colors.edge = get_pixel_color(intensity * 0.3, alpha * 0.1)
    
    return colors
end

-- Функция для создания градиентных частиц (для обратной совместимости)
local function get_particle_gradient_colors(intensity, alpha)
    -- Перенаправляем на новую функцию
    return get_pixel_gradient_colors(intensity, alpha)
end

-- Функция для отрисовки связей между пикселями
local function draw_pixel_connections(draw_list, pixels)
    if not PIXEL_CONFIG.enable_connections then return end
    
    local connection_distance = PIXEL_CONFIG.connection_distance
    local max_connections = PIXEL_CONFIG.max_connections
    
    for i, pixel1 in ipairs(pixels) do
        local connections_made = 0
        
        for j = i + 1, #pixels do
            if connections_made >= max_connections then break end
            
            local pixel2 = pixels[j]
            local dx = pixel2.x - pixel1.x
            local dy = pixel2.y - pixel1.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance < connection_distance and distance > 5 then
                -- Вычисляем альфа-канал связи на основе расстояния и интенсивности пикселей
                local connection_alpha = (1 - distance / connection_distance) * 
                                       (pixel1.alpha + pixel2.alpha) * 0.25
                
                if connection_alpha > 0.05 then
                    -- Создаем контрольные точки для Bezier-кривой
                    local mid_x = (pixel1.x + pixel2.x) * 0.5
                    local mid_y = (pixel1.y + pixel2.y) * 0.5
                    local curve_offset = math.sin(reaper.time_precise() * 2 + i + j) * 10
                    
                    local ctrl1_x = pixel1.x + dx * 0.3
                    local ctrl1_y = pixel1.y + dy * 0.3 + curve_offset
                    local ctrl2_x = pixel2.x - dx * 0.3
                    local ctrl2_y = pixel2.y - dy * 0.3 - curve_offset
                    
                    -- Цвет связи - смесь цветов пикселей
                    local avg_intensity = (pixel1.intensity + pixel2.intensity) * 0.5
                    local connection_color = get_pixel_color(avg_intensity, connection_alpha)
                    
                    -- Рисуем Bezier-кривую
                    reaper.ImGui_DrawList_AddBezierCubic(draw_list,
                        pixel1.x, pixel1.y,
                        ctrl1_x, ctrl1_y,
                        ctrl2_x, ctrl2_y,
                        pixel2.x, pixel2.y,
                        connection_color, 1.0, 0)
                    
                    connections_made = connections_made + 1
                end
            end
        end
    end
end

-- Функция для отрисовки связей между частицами (для обратной совместимости)
local function draw_particle_connections(draw_list, particles)
    -- Перенаправляем на новую функцию
    draw_pixel_connections(draw_list, particles)
end

-- Функция для отрисовки пульсирующих колец вокруг ярких пикселей
local function draw_pixel_rings(draw_list, x, y, pixel)
    if not PIXEL_CONFIG.enable_sparks or (pixel.intensity or 0) < PIXEL_CONFIG.spark_threshold then
        return
    end
    
    local time = reaper.time_precise()
    local ring_count = 2
    
    for i = 1, ring_count do
        local ring_phase = (time * 2 + (pixel.noise_offset or 0) + i * 0.5) % (math.pi * 2)
        local ring_radius = (pixel.size or 1) * (2 + i * 0.5) + math.sin(ring_phase) * (pixel.size or 1) * 0.3
        local ring_alpha = (pixel.alpha or 1.0) * 0.3 * (1 - i * 0.3) * (0.5 + 0.5 * math.sin(ring_phase))
        
        if ring_alpha > 0.05 then
            local ring_color = get_pixel_color((pixel.intensity or 0) * 0.6, ring_alpha)
            reaper.ImGui_DrawList_AddCircle(draw_list, x, y, ring_radius, ring_color, 0, 1.5)
        end
    end
end

-- Функция для отрисовки пульсирующих колец вокруг ярких частиц (для обратной совместимости)
local function draw_particle_rings(draw_list, x, y, particle)
    -- Перенаправляем на новую функцию
    draw_pixel_rings(draw_list, x, y, particle)
end

-- Функция для отображения панели настроек частиц
function draw_particle_settings_panel()
    if not show_particle_settings then 
        return 
    end
    
    -- Create context only once
    if not particle_ctx then
        particle_ctx = reaper.ImGui_CreateContext('Particle Settings')
        if not particle_ctx then
            return
        end
    end
    
    local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
    local visible, open = reaper.ImGui_Begin(particle_ctx, "Particle Effects Settings", true, flags)
    
    if visible then
        -- Основные настройки
        if reaper.ImGui_CollapsingHeader(particle_ctx, "Basic Settings", reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
            local changed, new_val
            
            changed, new_val = reaper.ImGui_SliderInt(particle_ctx, "Max Particles", PARTICLE_CONFIG.max_particles, 50, 500)
            if changed then PARTICLE_CONFIG.max_particles = new_val end
            
            changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Min Size", PARTICLE_CONFIG.particle_size_min, 1.0, 10.0, "%.1f")
            if changed then PARTICLE_CONFIG.particle_size_min = new_val end
            
            changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Max Size", PARTICLE_CONFIG.particle_size_max, 5.0, 20.0, "%.1f")
            if changed then PARTICLE_CONFIG.particle_size_max = new_val end
            
            changed, new_val = reaper.ImGui_SliderInt(particle_ctx, "Glow Layers", PARTICLE_CONFIG.glow_layers, 1, 10)
            if changed then PARTICLE_CONFIG.glow_layers = new_val end
            
            changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Fade Speed", PARTICLE_CONFIG.fade_speed, 0.90, 0.99, "%.3f")
            if changed then PARTICLE_CONFIG.fade_speed = new_val end
        end
        
        -- Настройки эффектов
        if reaper.ImGui_CollapsingHeader(particle_ctx, "Effect Settings", reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
            local changed, new_val
            
            changed, new_val = reaper.ImGui_Checkbox(particle_ctx, "Enable Ellipses", PARTICLE_CONFIG.enable_ellipses)
            if changed then PARTICLE_CONFIG.enable_ellipses = new_val end
            
            if PARTICLE_CONFIG.enable_ellipses then
                changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Ellipse Threshold", PARTICLE_CONFIG.ellipse_threshold, 0.1, 1.0, "%.2f")
                if changed then PARTICLE_CONFIG.ellipse_threshold = new_val end
            end
            
            changed, new_val = reaper.ImGui_Checkbox(particle_ctx, "Enable Sparks", PARTICLE_CONFIG.enable_sparks)
            if changed then PARTICLE_CONFIG.enable_sparks = new_val end
            
            if PARTICLE_CONFIG.enable_sparks then
                changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Spark Threshold", PARTICLE_CONFIG.spark_threshold, 0.1, 1.0, "%.2f")
                if changed then PARTICLE_CONFIG.spark_threshold = new_val end
            end
            
            changed, new_val = reaper.ImGui_Checkbox(particle_ctx, "Enable Connections", PARTICLE_CONFIG.enable_connections)
            if changed then PARTICLE_CONFIG.enable_connections = new_val end
            
            if PARTICLE_CONFIG.enable_connections then
                changed, new_val = reaper.ImGui_SliderDouble(particle_ctx, "Connection Distance", PARTICLE_CONFIG.connection_distance, 20.0, 200.0, "%.0f")
                if changed then PARTICLE_CONFIG.connection_distance = new_val end
                
                changed, new_val = reaper.ImGui_SliderInt(particle_ctx, "Max Connections", PARTICLE_CONFIG.max_connections, 1, 10)
                if changed then PARTICLE_CONFIG.max_connections = new_val end
            end
        end
        
        -- Кнопки сброса
        reaper.ImGui_Separator(particle_ctx)
        if reaper.ImGui_Button(particle_ctx, "Reset to Defaults") then
            PARTICLE_CONFIG.max_particles = 100
            PARTICLE_CONFIG.particle_size_min = 3
            PARTICLE_CONFIG.particle_size_max = 8
            PARTICLE_CONFIG.glow_layers = 4
            PARTICLE_CONFIG.fade_speed = 0.97
            PARTICLE_CONFIG.noise_amplitude = 3
            PARTICLE_CONFIG.enable_ellipses = true
            PARTICLE_CONFIG.enable_sparks = true
            PARTICLE_CONFIG.enable_connections = true
            PARTICLE_CONFIG.spark_threshold = 0.8
            PARTICLE_CONFIG.ellipse_threshold = 0.7
            PARTICLE_CONFIG.connection_distance = 50
            PARTICLE_CONFIG.max_connections = 3
        end
        
        reaper.ImGui_End(particle_ctx)
    end
    
    if not open then
        show_particle_settings = false
    end
end

-- Функция для отрисовки улучшенной частицы с градиентом
-- Функция для отрисовки улучшенного пикселя с эффектами
local function draw_enhanced_pixel(draw_list, x, y, pixel)
    local colors = get_pixel_gradient_colors(pixel.intensity or 0, pixel.alpha)
    
    -- Сначала рисуем пульсирующие кольца (на заднем плане)
    draw_pixel_rings(draw_list, x, y, pixel)
    
    -- Рисуем слои свечения с градиентом
    for layer = PIXEL_CONFIG.glow_layers, 1, -1 do
        local layer_size = (pixel.size or 1) * (1 + (layer - 1) * 0.5)
        local layer_alpha = (pixel.alpha or 1.0) / (layer * 1.5)
        
        if PIXEL_CONFIG.enable_ellipses and (pixel.intensity or 0) > PIXEL_CONFIG.ellipse_threshold then
            -- Высокая интенсивность: используем эллипсы для более динамичного вида
            local ellipse_w = layer_size * 1.2
            local ellipse_h = layer_size * 0.8
            local rotation = math.sin(reaper.time_precise() * 3 + pixel.noise_offset) * 0.3
            
            reaper.ImGui_DrawList_AddEllipseFilled(draw_list, x, y, ellipse_w, ellipse_h, 
                get_pixel_color(pixel.intensity or 0, layer_alpha), rotation)
        else
            -- Обычная интенсивность: круги
            reaper.ImGui_DrawList_AddCircleFilled(draw_list, x, y, layer_size, 
                get_pixel_color(pixel.intensity or 0, layer_alpha))
        end
    end
    
    -- Добавляем искры для очень ярких пикселей (на переднем плане)
    if PIXEL_CONFIG.enable_sparks and (pixel.intensity or 0) > PIXEL_CONFIG.spark_threshold and (pixel.alpha or 1.0) > 0.5 then
        local spark_count = 4
        local spark_length = (pixel.size or 1) * 2
        local time_offset = reaper.time_precise() * 5 + (pixel.noise_offset or 0)
        
        for i = 1, spark_count do
            local angle = (i / spark_count) * math.pi * 2 + time_offset
            local spark_x1 = x + math.cos(angle) * pixel.size
            local spark_y1 = y + math.sin(angle) * pixel.size
            local spark_x2 = x + math.cos(angle) * spark_length
            local spark_y2 = y + math.sin(angle) * spark_length
            
            reaper.ImGui_DrawList_AddLine(draw_list, spark_x1, spark_y1, spark_x2, spark_y2,
                get_pixel_color((pixel.intensity or 0) * 0.8, (pixel.alpha or 1.0) * 0.6), 1.5)
        end
    end
end

-- Функция для отрисовки улучшенной частицы (для обратной совместимости)
local function draw_enhanced_particle(draw_list, x, y, particle)
    -- Перенаправляем на новую функцию
    draw_enhanced_pixel(draw_list, x, y, particle)
end

-- Функция обновления системы частиц для трека с жесткими границами
-- Обновляем систему пикселей. Последний параметр `bar_y` (необязательный) –
-- позиция планки уровня dB‑метра, с которой частицы могут сталкиваться и
-- "подталкивать" её. Функция возвращает два значения: текущий уровень сигнала и
-- накопленное смещение планки от столкновений (push offset).
local function update_pixel_system(track_index, audio_level, delta_time, meter_height, meter_width, meter_x, meter_y, bar_y)
    -- Инициализируем систему пикселей, если она еще не существует
    if not pixel_systems[track_index] then
        init_pixel_system(track_index, meter_width, meter_height)
    end
    
    local system = pixel_systems[track_index]
    local current_time = reaper.time_precise()
    local actual_height = meter_height or PIXEL_CONFIG.meter_height
    local actual_width = meter_width or PIXEL_CONFIG.meter_width
    local actual_x = meter_x or 0
    local actual_y = meter_y or 0
    
    -- Рассчитываем энергию сигнала для воздействия на пиксели
    local signal_energy = audio_level * PIXEL_CONFIG.push_force
    
    -- Максимальное смещение от столкновений с планкой уровня (инициализируется нулём)
    local max_push = 0

    -- Обновляем все пиксели в системе (одномерный массив)
    for i = #system.pixels, 1, -1 do
        local pixel = system.pixels[i]
        
        -- Проверяем, что у пикселя есть все необходимые поля
        if not pixel.intensity then pixel.intensity = 0 end
        if not pixel.bounce_energy then pixel.bounce_energy = 0 end
        if not pixel.velocity_x then pixel.velocity_x = 0 end
        if not pixel.velocity_y then pixel.velocity_y = 0 end
        if not pixel.base_x then pixel.base_x = pixel.x end
        if not pixel.base_y then pixel.base_y = pixel.y end
        
        -- Обновляем интенсивность пикселя (затухание)
        pixel.intensity = (pixel.intensity or 0) * PIXEL_CONFIG.fade_speed
        
        -- Удаляем слабые пиксели
        if pixel.intensity < 0.01 then
            table.remove(system.pixels, i)
        else
            -- Добавляем энергию пикселям в зависимости от уровня сигнала
            if audio_level > 0.01 then
                local boost = signal_energy * delta_time
                
                -- Увеличиваем интенсивность и добавляем энергию для прыжка
                pixel.intensity = math.min(1.0, (pixel.intensity or 0) + boost)
                -- Уменьшаем коэффициент добавления энергии для более плавного отскока
                pixel.bounce_energy = (pixel.bounce_energy or 0) + boost * 20
            end
            
            -- Применяем физику: гравитация
            pixel.velocity_y = (pixel.velocity_y or 0) + PIXEL_CONFIG.gravity * delta_time
            
            -- Добавляем горизонтальное движение для эффекта волны
            local wave_offset = math.sin(current_time * PIXEL_CONFIG.wave_speed + i * 0.5) * PIXEL_CONFIG.wave_amplitude
            pixel.velocity_x = wave_offset * delta_time
            
            -- Обновляем позицию
            pixel.x = (pixel.base_x or pixel.x) + (pixel.velocity_x or 0)
            -- Меньший множитель для vertical displacement делает движение плавнее
            pixel.y = (pixel.base_y or pixel.y) - (pixel.bounce_energy or 0) * 0.25 + (pixel.velocity_y or 0)
            
            -- Проверяем границы метра
            local margin = 3
            local min_x = actual_x + margin
            local max_x = actual_x + actual_width - margin
            local min_y = actual_y + margin
            local max_y = actual_y + actual_height - margin
            
            -- Ограничиваем движение пикселя в пределах метра
            if pixel.x < min_x then
                pixel.x = min_x
                pixel.velocity_x = -(pixel.velocity_x or 0) * PIXEL_CONFIG.bounce_damping
            elseif pixel.x > max_x then
                pixel.x = max_x
                pixel.velocity_x = -(pixel.velocity_x or 0) * PIXEL_CONFIG.bounce_damping
            end
            
            if pixel.y < min_y then
                pixel.y = min_y
                pixel.velocity_y = -(pixel.velocity_y or 0) * PIXEL_CONFIG.bounce_damping
                pixel.bounce_energy = (pixel.bounce_energy or 0) * PIXEL_CONFIG.bounce_damping
            elseif pixel.y > max_y then
                pixel.y = max_y
                pixel.velocity_y = -(pixel.velocity_y or 0) * PIXEL_CONFIG.bounce_damping
                pixel.bounce_energy = 0 -- Сбрасываем энергию отскока при достижении дна
            end

            -- Столкновение с планкой уровня (верхняя граница активного уровня)
            if bar_y and pixel.y <= bar_y then
                -- Рассчитываем, насколько пиксель пересёк планку
                local overshoot = bar_y - pixel.y
                -- Смещаем пиксель на позицию планки
                pixel.y = bar_y
                -- Отбиваем частицу от планки с затуханием
                pixel.velocity_y = -(pixel.velocity_y or 0) * PIXEL_CONFIG.bounce_damping
                -- Эффект толчка: масштабируем пересечение
                local push = (overshoot or 0) * 0.5
                if push > max_push then
                    max_push = push
                end
                -- Дополнительно уменьшаем энергию отскока после столкновения
                pixel.bounce_energy = (pixel.bounce_energy or 0) * PIXEL_CONFIG.bounce_damping
            end
            
            -- Постепенно уменьшаем энергию отскока
            pixel.bounce_energy = (pixel.bounce_energy or 0) * (1 - PIXEL_CONFIG.settle_speed * delta_time)
        end
    end
    
    -- Возвращаем уровень сигнала и максимальное смещение толчка (push offset)
    return audio_level, max_push
end

-- Функция обновления системы частиц (для обратной совместимости)
local function update_particle_system(track_index, audio_level, delta_time, meter_height, meter_width, meter_x, meter_y)
    -- Перенаправляем на новую функцию
    return update_pixel_system(track_index, audio_level, delta_time, meter_height, meter_width, meter_x, meter_y)
end

-- Функция отрисовки частиц с жестким ограничением внутри метра
-- Функция отрисовки пиксельной системы
local function draw_pixel_system(ctx, x, y, track_index)
    if not pixel_systems[track_index] then
        return
    end
    
    local system = pixel_systems[track_index]
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Определяем жесткие границы метра для отрисовки
    local margin = 2
    local min_x = x + margin
    local max_x = x + PIXEL_CONFIG.meter_width - margin
    local min_y = y + margin
    local max_y = y + PIXEL_CONFIG.meter_height - margin
    
    -- Отрисовываем каждый пиксель с несколькими слоями для эффекта свечения (одномерный массив)
    for _, pixel in ipairs(system.pixels) do
        -- ЖЕСТКО проверяем, что пиксель находится внутри границ метра
        if pixel.x >= min_x and pixel.x <= max_x and 
           pixel.y >= min_y and pixel.y <= max_y then
            
            -- Рисуем слои свечения (от большего к меньшему)
            for layer = PIXEL_CONFIG.glow_layers, 1, -1 do
                local pixel_size = PIXEL_CONFIG.pixel_size
                local layer_size = pixel_size * (1 + (layer - 1) * 0.5)
                local layer_alpha = (pixel.alpha or 1.0) / (layer * 1.5)
                local color = get_pixel_color(pixel.intensity or 0, layer_alpha)
                
                -- Рисуем пиксель как заполненный круг
                reaper.ImGui_DrawList_AddCircleFilled(draw_list, pixel.x, pixel.y, layer_size, color)
            end
        end
    end
end

-- Функция отрисовки системы частиц (для обратной совместимости)
local function draw_particle_system(ctx, x, y, track_index)
    -- Перенаправляем на новую функцию
    draw_pixel_system(ctx, x, y, track_index)
end

-- Функция получения уровня аудио трека
local function get_track_audio_level(track_index)
    -- Проверяем корректность track_index
    if not track_index or type(track_index) ~= "number" then
        return 0
    end
    
    if track_index == 0 then
        -- Мастер трек (i == 0)
        local master_track = reaper.GetMasterTrack(0)
        if master_track then
            local peak_l = reaper.Track_GetPeakInfo(master_track, 0) or 0
            local peak_r = reaper.Track_GetPeakInfo(master_track, 1) or 0
            local max_peak = math.max(peak_l, peak_r)
            -- Применяем усиление для лучшей видимости, но не ограничиваем максимум
            local amplified_level = max_peak * 2.5
            -- Добавляем небольшое сглаживание для более стабильной работы
            if amplified_level < 0.001 then
                return 0
            end
            return amplified_level
        end
    else
        -- Обычный трек (i >= 1, поэтому track_index - 1 для получения правильного трека)
        local track = reaper.GetTrack(0, track_index - 1)
        if track then
            local peak_l = reaper.Track_GetPeakInfo(track, 0) or 0
            local peak_r = reaper.Track_GetPeakInfo(track, 1) or 0
            local max_peak = math.max(peak_l, peak_r)
            -- Применяем усиление для лучшей видимости, но не ограничиваем максимум
            local amplified_level = max_peak * 2.5
            -- Добавляем небольшое сглаживание для более стабильной работы
            if amplified_level < 0.001 then
                return 0
            end
            return amplified_level
        end
    end
    return 0
end

-- FL-style функция обновления частиц с жесткими границами метра
function UpdateFXParticlesFL(track_index, level, meter_x, meter_y, meter_width, meter_height, handle_y)
    -- Используем пиксельную систему вместо fx_particles
    local system = init_pixel_system(track_index, meter_width, meter_height)
    local current_time = reaper.time_precise()
    local delta_time = 1.0 / 60.0
    
    -- Определяем границы метра используя ImGui.GetItemRectMin/Max подход
    local margin = 3
    local meter_min_x = meter_x + margin
    local meter_max_x = meter_x + meter_width - margin
    local meter_min_y = meter_y + margin
    local meter_max_y = meter_y + meter_height - margin
    
    -- Фильтрация мертвых частиц и обновление живых
    for i = #system.pixels, 1, -1 do
        local particle = system.pixels[i]
        
        -- Обновляем время жизни частицы
        particle.life = particle.life - delta_time
        
        -- Простая физика: движение вверх с гравитацией
        particle.velocity_y = particle.velocity_y + particle.gravity * delta_time
        local new_y = particle.y + particle.velocity_y * delta_time
        
        -- Обновляем горизонтальную позицию с учетом velocity_x
        local new_x = particle.x + particle.velocity_x * delta_time
        
        -- Обновляем позицию
        particle.x = new_x
        particle.y = new_y
        
        -- Отскоки от границ метра (как в GPTDb метр новый)
        -- Отскок от левой и правой стенок
        if particle.x <= meter_min_x or particle.x >= meter_max_x then
            particle.velocity_x = -particle.velocity_x * 0.5  -- Отскок с затуханием
            particle.x = math.max(meter_min_x, math.min(meter_max_x, particle.x))
        end
        
        -- Отскок от верха и низа метра
        if particle.y <= meter_min_y then
            particle.velocity_y = -particle.velocity_y * 0.5  -- Отскок от верха
            particle.y = meter_min_y
        elseif particle.y >= meter_max_y then
            particle.velocity_y = -particle.velocity_y * 0.5  -- Отскок от низа
            particle.y = meter_max_y
            -- Добавляем небольшое боковое отклонение при отскоке от дна
            particle.velocity_x = particle.velocity_x + (math.random() - 0.5) * 5
        end
        
        -- Взаимодействие с ползунком дБ (если позиция передана)
        if handle_y and particle.velocity_y < 0 then  -- Частица движется вверх
            local handle_tolerance = 5  -- Толщина области взаимодействия с ползунком
            -- Проверяем, находится ли частица в зоне ползунка
            if particle.y <= handle_y + handle_tolerance and particle.y >= handle_y - handle_tolerance then
                -- Отскок от ползунка вниз
                particle.velocity_y = -math.abs(particle.velocity_y) * 0.8  -- Отскок вниз с затуханием
                particle.y = handle_y + handle_tolerance  -- Позиционируем ниже ползунка
                -- Добавляем небольшое боковое отклонение при отскоке от ползунка
                particle.velocity_x = particle.velocity_x + (math.random() - 0.5) * 10
            end
        end
        
        -- Затухание скоростей
        particle.velocity_x = particle.velocity_x * 0.98
        particle.velocity_y = particle.velocity_y * 0.995
        
        -- Обновляем альфа-канал (затухание)
        particle.alpha = particle.alpha * PIXEL_CONFIG.fade_speed
        
        -- Удаляем мертвые частицы (вышедшие за границы, прозрачные или проживших слишком долго)
        local out_of_bounds = particle.x < meter_min_x or particle.x > meter_max_x or
                             particle.y < meter_min_y or particle.y > meter_max_y
        local is_dead = out_of_bounds or particle.alpha < 0.01 or particle.life <= 0
        
        if is_dead then
            table.remove(system.pixels, i)
        end
    end
    
    -- Создаем новые частицы на основе уровня аудио
    local particles_to_create = 0
    if level > 0.001 then
        particles_to_create = math.floor(level * PIXEL_CONFIG.max_particles * delta_time * 20)
        particles_to_create = math.max(1, particles_to_create)
    end
    
    for i = 1, particles_to_create do
        if #system.pixels < PIXEL_CONFIG.max_particles then
            -- Создаем частицы строго в пределах meter_min/max границ
            local safe_width = meter_max_x - meter_min_x
            local safe_height = meter_max_y - meter_min_y
            
            if safe_width > 0 and safe_height > 0 then
                local pixel_x = meter_min_x + (math.random() * safe_width)
            local pixel_y = meter_max_y - (math.random() * 10) -- Появляются в нижней части
            local pixel = create_pixel(
                pixel_x, pixel_y, level, level, 
                meter_width, meter_min_x, meter_min_y, meter_height
            )
            
            -- Устанавливаем базовую позицию для движения в безопасной зоне
            pixel.base_x = pixel_x
            
            table.insert(system.pixels, pixel)
            end
        end
    end
    
    return 0  -- Возвращаем 0 вместо сложного расчета давления
end

-- Функция отрисовки пиксельной системы
function DrawPixelSystem(track_index, draw_list, meter_x, meter_y, meter_width, meter_height)
    if not pixel_systems[track_index] then
        return
    end
    
    local system = pixel_systems[track_index]
    
    -- Границы метра
    local margin = 3
    local meter_min_x = meter_x + margin
    local meter_max_x = meter_x + meter_width - margin
    local meter_min_y = meter_y + margin
    local meter_max_y = meter_y + meter_height - margin
    
    -- Отрисовываем пиксели в стиле LED / LCD
    for _, pixel in ipairs(system.pixels) do
        local intensity = pixel.intensity or 0
        -- фильтруем слишком слабые пиксели
        if intensity > 0.01 then
            -- абсолютные координаты пикселя
            local abs_x = pixel.x
            local abs_y = pixel.y
            -- проверяем, что пиксель внутри границ метра
            if abs_x >= meter_min_x and abs_x <= meter_max_x and 
               abs_y >= meter_min_y and abs_y <= meter_max_y then
                -- выбираем размер LED‑пикселя (используем размер частицы или конфиг)
                local size = pixel.size or PIXEL_CONFIG.pixel_size
                -- координаты левого верхнего угла для функции draw_lcd_pixel
                local px = abs_x - size/2
                local py = abs_y - size/2
                -- вычисляем частотный коэффициент по вертикальному положению: нижняя часть → низкие частоты (0), верхняя → высокие (1)
                local freq_factor = 0.0
                local denom = meter_max_y - meter_min_y
                if denom > 0 then
                    freq_factor = math.max(0.0, math.min(1.0, (meter_max_y - abs_y) / denom))
                end
                -- рисуем LED‑пиксель с использованием функции draw_lcd_pixel
                draw_lcd_pixel(draw_list, px, py, size, size, intensity, freq_factor)
            end
        end
    end
end

-- Функция очистки неиспользуемых систем пикселей
local function cleanup_pixel_systems(max_track_count)
    for track_index in pairs(pixel_systems) do
        if track_index > max_track_count then
            pixel_systems[track_index] = nil
        end
    end
end

-- Функция отрисовки спектрального метра
local function draw_spectrum_meter(ctx, x, y, track_index, meter_height)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Используем переданную высоту или значение по умолчанию
    local actual_height = meter_height or PIXEL_CONFIG.meter_height
    
    -- Фон метра: рисуем чёрную заливку, чтобы дым и пиксели отображались на темном фоне
    local bg_color = 0x000000FF
    reaper.ImGui_DrawList_AddRectFilled(draw_list, 
        x, y, 
        x + PIXEL_CONFIG.meter_width, y + actual_height, 
        bg_color, 2)
    
    -- Рамка метра
    local border_color = 0x404040FF
    reaper.ImGui_DrawList_AddRect(draw_list, 
        x, y, 
        x + PIXEL_CONFIG.meter_width, y + actual_height, 
        border_color, 2, 0, 1)
    
    -- Рисуем дБ шкалу (как в слайдере громкости)
    local min_db = -60  -- Минимум -60 дБ
    local max_db = 12   -- Максимум +12 дБ
    local scale_marks = {12, 6, 0, -6, -12, -18, -24, -30, -40, -50}
    
    for _, db_val in ipairs(scale_marks) do
        if db_val >= min_db and db_val <= max_db then
            -- Вычисляем позицию метки (0 = верх метра, 1 = низ метра)
            local mark_normalized = (db_val - min_db) / (max_db - min_db)
            local mark_y = y + (1 - mark_normalized) * actual_height
            
            if db_val == 0 then
                -- 0dB - более заметная отметка (как в слайдере)
                reaper.ImGui_DrawList_AddLine(draw_list, 
                    x + PIXEL_CONFIG.meter_width + 2, mark_y, 
                    x + PIXEL_CONFIG.meter_width + 6, mark_y, 
                    0x808080FF, 2)
            elseif db_val % 12 == 0 then
                -- Основные отметки (каждые 12dB)
                reaper.ImGui_DrawList_AddLine(draw_list, 
                    x + PIXEL_CONFIG.meter_width + 2, mark_y, 
                    x + PIXEL_CONFIG.meter_width + 5, mark_y, 
                    0x606060FF, 1)
            else
                -- Промежуточные отметки
                reaper.ImGui_DrawList_AddLine(draw_list, 
                    x + PIXEL_CONFIG.meter_width + 2, mark_y, 
                    x + PIXEL_CONFIG.meter_width + 4, mark_y, 
                    0x404040FF, 1)
            end
        end
    end
    
    -- Инициализируем время обновления для трека, если его нет
    if not last_update_times[track_index] then
        last_update_times[track_index] = 0
    end
    
    -- Получаем уровень аудио и обновляем частицы
    local current_time = reaper.time_precise()
    local delta_time = current_time - last_update_times[track_index]
    local audio_level = get_track_audio_level(track_index) or 0
    
    -- Вычисляем позицию планки уровня сигнала для передачи в систему частиц
    local signal_level_y = y + actual_height -- По умолчанию внизу метра
    if audio_level and audio_level > 0.00001 then
        local level_db = 20 * (math.log(audio_level) / math.log(10))
        local min_db = -60
        local max_db = 12
        level_db = math.max(min_db, math.min(max_db, level_db))
        local level_normalized = (level_db - min_db) / (max_db - min_db)
        signal_level_y = y + (1 - level_normalized) * actual_height
    end
    
    -- Сохраняем предыдущее смещение планки для корректной физики столкновений
    local prev_push = pixel_push_offsets[track_index] or 0
    -- Планка, используемая для системы частиц: учитывает предыдущее смещение
    local bar_y_for_bounce = signal_level_y - prev_push
    -- Обновляем системы тумана и вспрыгивающих пикселей и сохраняем смещение от столкновений
    local push_offset = 0
    if delta_time > 1.0 / PIXEL_CONFIG.update_rate then
        -- Обновляем густой туман: частицы колышутся, но не выходят за планку и рамки
        update_fog_system(track_index, audio_level, delta_time, x, y, PIXEL_CONFIG.meter_width, actual_height, bar_y_for_bounce)
        -- Обновляем bounce‑систему: частицы выпрыгивают из верхней части тумана и отскакивают от планки
        local new_push = update_bounce_system(track_index, audio_level, delta_time, bar_y_for_bounce, x, y, PIXEL_CONFIG.meter_width, actual_height)
        push_offset = new_push or 0
        -- Запоминаем новое смещение, чтобы в следующем кадре корректно определять планку столкновений
        pixel_push_offsets[track_index] = push_offset
        last_update_times[track_index] = current_time
    end
    -- Рисуем туман под планкой
    draw_fog_system(ctx, x, y, track_index, PIXEL_CONFIG.meter_width, actual_height)
    -- Рисуем вспрыгивающие пиксели поверх тумана
    draw_bounce_system(ctx, track_index, x, y, PIXEL_CONFIG.meter_width, actual_height)
    -- Рисуем линию индикатора уровня дБ (планка). Используем signal_level_y и push_offset
    do
        local bar_y_draw = signal_level_y - (push_offset or 0)
        if bar_y_draw < y then bar_y_draw = y end
        reaper.ImGui_DrawList_AddLine(draw_list,
            x + 2, bar_y_draw,
            x + PIXEL_CONFIG.meter_width - 2, bar_y_draw,
            0x00FFFFFF, 1)
    end
    
    -- СПЕКТРОАНАЛИЗАТОР: рисуем столбики пикселей для разных частотных полос
    -- Отключено (условие всегда false), чтобы под планкой не появлялось синее закрашивание
    if false and audio_level and audio_level > 0.00001 then
        -- audio_level приходит как линейное значение амплитуды от Track_GetPeakInfo
        -- Преобразуем в дБ как в Reaper: dB = 20 * log10(amplitude)
        local level_db = 20 * (math.log(audio_level) / math.log(10))
        
        -- Ограничиваем диапазон отображения
        local min_db = -60
        local max_db = 12
        level_db = math.max(min_db, math.min(max_db, level_db))
        
        -- Нормализуем уровень (0 = тишина, 1 = максимум)
        local level_normalized = (level_db - min_db) / (max_db - min_db)
        
        -- Вычисляем позицию планки уровня сигнала
        local level_y = y + (1 - level_normalized) * actual_height
        -- Смещение планки от всплесков частиц (push_offset)
        level_y = level_y - (push_offset or 0)
        if level_y < y then level_y = y end
        
        -- Настройки спектроанализатора
        local num_columns = 8           -- Количество частотных полос (столбцов)
        local column_gap = 1            -- Зазор между столбцами
        local pixel_height = 3          -- Высота одного пикселя
        local pixel_gap = 1             -- Зазор между пикселями в столбце
        local pixel_step = pixel_height + pixel_gap
        
        -- Вычисляем ширину одного столбца
        local total_gaps = (num_columns - 1) * column_gap
        local available_width = PIXEL_CONFIG.meter_width - 2 - total_gaps  -- -2 для отступов по краям
        local column_width = math.floor(available_width / num_columns)
        
        -- Максимальное количество пикселей в столбце (ограничено планкой)
        local max_pixels_in_column = math.floor(actual_height / pixel_step)
        local level_pixels_limit = math.floor((y + actual_height - level_y) / pixel_step)
        
        -- Advanced spectrum animation with JSFX-inspired techniques
        local current_time_ms = reaper.time_precise() * 1000
        local dt = current_time_ms - last_spectrum_time
        last_spectrum_time = current_time_ms
        
        -- Инициализируем буферы для данного трека
        if not spectrum_column_levels[track_index] then
            spectrum_column_levels[track_index] = {}
            spectrum_integration_buffer[track_index] = {}
            spectrum_peak_hold[track_index] = {}
            spectrum_fall_rate[track_index] = {}
            for i = 1, num_columns do
                spectrum_column_levels[track_index][i] = 0
                spectrum_integration_buffer[track_index][i] = 0
                spectrum_peak_hold[track_index][i] = {value = 0, time = 0}
                spectrum_fall_rate[track_index][i] = 0
            end
        end
        
        -- Отрисовываем каждый столбец (частотную полосу)
        for col = 1, num_columns do
            -- Позиция столбца
            local column_x = x + 1 + (col - 1) * (column_width + column_gap)
            
            -- Симулируем разные частотные полосы
            local frequency_factor = col / num_columns  -- 0.125 до 1.0
            
            -- Создаем целевой уровень для каждой частотной полосы
            local base_level = level_normalized
            
            -- Добавляем очень мягкие частотно-зависимые вариации
            local freq_variation = 1.0
            if frequency_factor < 0.3 then
                -- Низкие частоты: больше энергии при басах
                freq_variation = 0.98 + math.random() * 0.04 + base_level * 0.05
            elseif frequency_factor < 0.7 then
                -- Средние частоты: стабильные
                freq_variation = 0.96 + math.random() * 0.06 + base_level * 0.08
            else
                -- Высокие частоты: более хаотичные, но очень мягко
                freq_variation = 0.94 + math.random() * 0.08 + base_level * 0.04
            end
            
            -- Минимальные временные флуктуации
            local time_factor = math.sin(current_time * (0.2 + frequency_factor * 0.5)) * 0.02 + 1.0
            local raw_level = math.min(1.0, base_level * freq_variation * time_factor)
            
            -- Apply frequency slope compensation (subtle)
            local target_level = apply_frequency_slope(raw_level, col, num_columns, 1.0)
            
            -- Integration smoothing (like JSFX integration_time)
            local integration_rate = 5000.0 / math.max(integration_time, 1)
            spectrum_integration_buffer[track_index][col] = exponential_smooth(
                spectrum_integration_buffer[track_index][col], 
                target_level, 
                integration_rate, 
                dt
            )
            
            local integrated_level = spectrum_integration_buffer[track_index][col]
            
            -- Peak hold with decay
            local peak_data = spectrum_peak_hold[track_index][col]
            if integrated_level > peak_data.value then
                peak_data.value = integrated_level
                peak_data.time = current_time_ms
            elseif current_time_ms - peak_data.time > peak_hold_time then
                -- Peak decay
                local decay_rate = 2.0  -- dB/sec equivalent
                peak_data.value = exponential_smooth(peak_data.value, integrated_level, decay_rate, dt)
            end
            
            -- Adaptive fall rate (faster for sudden drops, slower for gradual)
            local current_level = spectrum_column_levels[track_index][col] or 0
            local level_diff = integrated_level - current_level
            
            local fall_rate_base = 4.0  -- Base fall rate
            local rise_rate = 10.0      -- Rise rate
            
            if level_diff > 0 then
                -- Rising: use rise rate
                spectrum_fall_rate[track_index][col] = rise_rate
            else
                -- Falling: adaptive rate based on difference magnitude
                local adaptive_factor = math.min(math.abs(level_diff) * 8, 3.0)
                spectrum_fall_rate[track_index][col] = fall_rate_base * (1 + adaptive_factor)
            end
            
            -- Apply smoothing with adaptive rate
            spectrum_column_levels[track_index][col] = exponential_smooth(
                current_level, 
                integrated_level, 
                spectrum_fall_rate[track_index][col], 
                dt
            )
            
            local smooth_level = spectrum_column_levels[track_index][col]
            
            -- Вычисляем количество активных пикселей (ограничено планкой)
            local target_pixels = math.floor(smooth_level * max_pixels_in_column)
            local active_pixels = math.min(target_pixels, level_pixels_limit)
            
            -- Отрисовываем LCD пиксели в столбце снизу вверх
            for pixel_row = 1, active_pixels do
                local pixel_y = y + actual_height - pixel_row * pixel_step
                
                -- ВАЖНО: Проверяем, что пиксель не выше планки уровня
                if pixel_y >= level_y then
                    -- Определяем интенсивность пикселя в зависимости от позиции в столбце
                    local pixel_position = pixel_row / math.max(1, active_pixels)
                    local base_intensity = 1.0 - pixel_position * 0.2  -- Уменьшен градиент для большей яркости
                    base_intensity = math.max(0.4, base_intensity)  -- Минимальная яркость увеличена
                    
                    -- Используем LCD эффект вместо обычных пикселей с увеличенной яркостью
                    draw_lcd_pixel(draw_list, column_x, pixel_y, column_width, pixel_height, 
                                 base_intensity * 1.2, frequency_factor)  -- Дополнительное увеличение яркости
                end
            end
            
            -- Индикатор удержания пика (LCD стиль)
            local peak_level = peak_data.value
            if peak_level > 0.01 and peak_level > smooth_level + 0.03 then
                local peak_y = y + actual_height - math.floor(peak_level * max_pixels_in_column) * pixel_step
                if peak_y >= level_y then
                    -- Используем LCD пиксель для пика с оранжевым цветом
                    -- Создаем специальный frequency_factor для оранжевого цвета
                    local orange_freq_factor = 0.15  -- Это даст оранжевый цвет в нашей LCD палитре
                    draw_lcd_pixel(draw_list, column_x, peak_y, column_width, pixel_height, 
                                 1.0, orange_freq_factor)  -- Максимальная интенсивность для пика
                end
            end
        end
        
        -- Яркая линия на уровне сигнала (поверх пикселей)
        local line_color = 0x00FFFFFF  -- Яркий cyan
        reaper.ImGui_DrawList_AddLine(draw_list, 
            x + 2, level_y, 
            x + PIXEL_CONFIG.meter_width - 2, level_y, 
            line_color, 1)
    end
end

-- Функция отрисовки градиентного фона трека с цветами Reaper
local function draw_gradient_track_background(ctx, x, y, width, height, track_index, is_selected)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Функция получения стандартного цвета трека (как в Reaper, без библиотеки)
    local function get_standard_track_color(track_index)
        if track_index == 0 then
            return 0x404040FF -- Мастер трек (серый как в Reaper)
        end
        
        local track = reaper.GetTrack(0, track_index - 1)
        if track then
            local reaper_color = reaper.GetTrackColor(track)
            if reaper_color ~= 0 then
                -- Стандартная конвертация как в оригинальном микшере
                local r = reaper_color & 0xFF
                local g = (reaper_color >> 8) & 0xFF
                local b = (reaper_color >> 16) & 0xFF
                return (r << 24) | (g << 16) | (b << 8) | 0xFF
            end
        end
        
        -- Цвет по умолчанию (серый)
        return 0x404040FF
    end
    
    -- Локальная функция интерполяции с правильным альфа-каналом
    local function interpolate_rgba(color1, color2, factor)
        factor = math.max(0, math.min(1, factor))
        
        -- Извлекаем RGBA компоненты
        local r1 = (color1 >> 24) & 0xFF
        local g1 = (color1 >> 16) & 0xFF
        local b1 = (color1 >> 8) & 0xFF
        local a1 = color1 & 0xFF
        
        local r2 = (color2 >> 24) & 0xFF
        local g2 = (color2 >> 16) & 0xFF
        local b2 = (color2 >> 8) & 0xFF
        local a2 = color2 & 0xFF
        
        -- Интерполируем каждый компонент
        local r = math.floor(r1 + (r2 - r1) * factor)
        local g = math.floor(g1 + (g2 - g1) * factor)
        local b = math.floor(b1 + (b2 - b1) * factor)
        local a = math.floor(a1 + (a2 - a1) * factor)
        
        return (r << 24) | (g << 16) | (b << 8) | a
    end

    -- Функция для приглушения цвета трека (делает его тусклее и матовее)
    local function mute_track_color(color)
        local r = (color >> 24) & 0xFF
        local g = (color >> 16) & 0xFF
        local b = (color >> 8) & 0xFF
        local a = color & 0xFF
        
        -- Еще больше уменьшаем насыщенность и затемняем для более матового эффекта
        local saturation_factor = 0.55  -- Уменьшаем насыщенность на 45% (было 30%)
        local brightness_factor = 0.75   -- Затемняем на 25% (было 15%)
        
        -- Находим среднее значение для уменьшения насыщенности
        local avg = (r + g + b) / 3
        
        -- Смешиваем с серым для уменьшения насыщенности
        r = r * saturation_factor + avg * (1 - saturation_factor)
        g = g * saturation_factor + avg * (1 - saturation_factor)
        b = b * saturation_factor + avg * (1 - saturation_factor)
        
        -- Применяем затемнение
        r = r * brightness_factor
        g = g * brightness_factor
        b = b * brightness_factor
        
        -- Ограничиваем значения
        r = math.max(0, math.min(255, math.floor(r)))
        g = math.max(0, math.min(255, math.floor(g)))
        b = math.max(0, math.min(255, math.floor(b)))
        
        return (r << 24) | (g << 16) | (b << 8) | a
    end

    -- Получаем стандартный цвет трека (точно как в Reaper)
    local track_color = get_standard_track_color(track_index)
    
    -- Приглушаем цвет трека, чтобы он не бил по глазам
    track_color = mute_track_color(track_color)
    
    -- Определяем интенсивность градиента в зависимости от выделения
    local gradient_intensity = is_selected and 0.7 or 0.5  -- 70% для выделенных (более заметно), 50% для невыделенных
    
    -- Для выделенных треков делаем цвет трека ярче
    if is_selected then
        local r = (track_color >> 24) & 0xFF
        local g = (track_color >> 16) & 0xFF
        local b = (track_color >> 8) & 0xFF
        local a = track_color & 0xFF
        
        -- Увеличиваем яркость выделенного трека на 20%
        local brightness_boost = 1.2
        r = math.min(255, math.floor(r * brightness_boost))
        g = math.min(255, math.floor(g * brightness_boost))
        b = math.min(255, math.floor(b * brightness_boost))
        
        track_color = (r << 24) | (g << 16) | (b << 8) | a
    end
    
    -- Создаем вертикальный градиент для всех треков
    local steps = 256  -- Ультра-плавный градиент
    
    for i = 0, steps - 1 do
        local t = i / (steps - 1)  -- Позиция от 0 (верх) до 1 (низ)
        
        -- Определяем зоны градиента
        local center_start = 0.18  -- Начало центральной зоны (18% от верха)
        local center_end = 0.82    -- Конец центральной зоны (82% от верха)
        
        local mix_factor = 0  -- По умолчанию натуральный цвет трека
        
        if t < center_start then
            -- Верхняя зона перехода (0% - 18%)
            local transition_pos = t / center_start  -- От 0 до 1 в верхней зоне
            -- S-образная кривая: 0.5 * (1 - cos(π * x))
            local smooth_transition = 0.5 * (1 - math.cos(math.pi * transition_pos))
            -- Инвертируем: в самом верху максимум темы, к центру - натуральный цвет
            mix_factor = (1 - smooth_transition) * gradient_intensity
            
        elseif t > center_end then
            -- Нижняя зона перехода (82% - 100%)
            local transition_pos = (t - center_end) / (1 - center_end)  -- От 0 до 1 в нижней зоне
            -- S-образная кривая: 0.5 * (1 - cos(π * x))
            local smooth_transition = 0.5 * (1 - math.cos(math.pi * transition_pos))
            -- К низу увеличиваем влияние темы
            mix_factor = smooth_transition * gradient_intensity
            
        else
            -- Центральная зона (18% - 82%) - полностью натуральный цвет трека
            mix_factor = 0
        end
        
        -- НАСТОЯЩЕЕ СМЕШИВАНИЕ: интерполируем между цветом трека и THEME_COLOR
        local mixed_color = interpolate_rgba(track_color, THEME_COLOR, mix_factor)
        
        local grad_y1 = y + (height * i) / steps
        local grad_y2 = y + (height * (i + 1)) / steps
        
        reaper.ImGui_DrawList_AddRectFilled(dl, x, grad_y1, x + width, grad_y2, mixed_color)
    end
    
    -- Добавляем яркую рамку для выделенных треков
    if is_selected then
        local border_color = 0xFFFFFFFF  -- Белая рамка
        local border_thickness = 2
        reaper.ImGui_DrawList_AddRect(dl, x, y, x + width, y + height, border_color, 0, 0, border_thickness)
    end
end

-- Константы
local DEFAULT_SEND_LEVEL = 0.833333  -- Нормализованное значение для 0 дБ

local ctx = nil
local font, font_small, font_tiny, font_micro

local function SetupContext()
    ctx = reaper.ImGui_CreateContext('FL Mixer Table Select')
    font = reaper.ImGui_CreateFont('sans-serif', 14)
    font_small = reaper.ImGui_CreateFont('Arial', 11)  -- Более читаемый шрифт
    font_tiny = reaper.ImGui_CreateFont('sans-serif', 10)
    font_micro = reaper.ImGui_CreateFont('sans-serif', 8)  -- Еще более мелкий шрифт для маленьких крутилок
    reaper.ImGui_Attach(ctx, font)
    reaper.ImGui_Attach(ctx, font_small)
    reaper.ImGui_Attach(ctx, font_tiny)
    reaper.ImGui_Attach(ctx, font_micro)
end

-- Функция для инициализации данных посылов
-- Таблицы для хранения данных посылов по GUID треков
local send_levels_by_guid = {}  -- [source_guid][dest_guid] = level
local send_states_by_guid = {}  -- [source_guid][dest_guid] = true/false

-- Функция для обновления GUID таблиц при изменении send_levels
local function update_guid_tables_for_send(source_index, dest_index, level, state)
    if source_index and dest_index then
        local source_track = (source_index == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, source_index - 1)
        local dest_track = (dest_index == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, dest_index - 1)
        
        if source_track and dest_track then
            local source_guid = reaper.GetTrackGUID(source_track)
            local dest_guid = reaper.GetTrackGUID(dest_track)
            
            if not send_levels_by_guid[source_guid] then send_levels_by_guid[source_guid] = {} end
            if not send_states_by_guid[source_guid] then send_states_by_guid[source_guid] = {} end
            
            if level ~= nil then
                send_levels_by_guid[source_guid][dest_guid] = level
            end
            if state ~= nil then
                send_states_by_guid[source_guid][dest_guid] = state
            end
        end
    end
end

local function init_send_data()
    -- Очищаем текущие данные
    send_levels = {}
    send_states = {}
    send_levels_by_guid = {}
    send_states_by_guid = {}
    
    -- Получаем количество треков в проекте
    local track_count = reaper.CountTracks(0)
    
    -- Проходим по всем трекам и инициализируем данные посылов
    for i = 0, track_count - 1 do
        local source_track = reaper.GetTrack(0, i)
        if source_track then
            local source_guid = reaper.GetTrackGUID(source_track)
            
            -- Получаем количество посылов с этого трека
            local send_count = reaper.GetTrackNumSends(source_track, 0)
            
            for send_idx = 0, send_count - 1 do
                -- Получаем трек назначения для этого посыла
                local dest_track = reaper.GetTrackSendInfo_Value(source_track, 0, send_idx, "P_DESTTRACK")
                if dest_track then
                    local dest_guid = reaper.GetTrackGUID(dest_track)
                    
                    -- Находим индекс трека назначения для совместимости с UI
                    local dest_idx = -1
                    for j = 0, track_count - 1 do
                        if reaper.GetTrack(0, j) == dest_track then
                            dest_idx = j
                            break
                        end
                    end
                    
                    if dest_idx >= 0 then
                        -- Получаем уровень посыла из Reaper
                        local send_level = reaper.GetTrackSendInfo_Value(source_track, 0, send_idx, "D_VOL")
                        -- Конвертируем линейное значение в нормализованный уровень (0-1)
                        local level_db = 20 * (math.log(send_level) / math.log(10))
                        local normalized_level = (level_db + 60) / 72
                        normalized_level = math.max(0, math.min(1, normalized_level))
                        
                        -- Сохраняем по GUID (основное хранилище)
                        if not send_levels_by_guid[source_guid] then send_levels_by_guid[source_guid] = {} end
                        if not send_states_by_guid[source_guid] then send_states_by_guid[source_guid] = {} end
                        
                        send_levels_by_guid[source_guid][dest_guid] = normalized_level
                        send_states_by_guid[source_guid][dest_guid] = true
                        
                        -- Также сохраняем по индексам для совместимости с UI (используем 1-based индексы)
                        if not send_levels[i + 1] then send_levels[i + 1] = {} end
                        if not send_states[i + 1] then send_states[i + 1] = {} end
                        
                        send_levels[i + 1][dest_idx + 1] = normalized_level
                        send_states[i + 1][dest_idx + 1] = true
                    end
                end
            end
        end
    end
end

local selected_track_index = -1
local selected_track = nil  -- Переменная для хранения выбранного трека
local selected_tracks = {}  -- Таблица для хранения множественного выделения треков
local track_colors = {}
local track_names = {}

-- Переменные для копирования значений (общие для громкости и сендов)
local copied_value_db = nil  -- Общая переменная для копирования в dB

-- Переменные для контекстного меню панорамы
local copied_pan = nil

-- Переменные для контекстного меню mix knob
local copied_mix = nil

-- Переменные для контекстного меню стереоразделения
local copied_stereo = nil

-- Переменные для сендов
local send_levels = {}  -- Уровни сендов [source_track][dest_track] = level (0.0-1.0)
local send_states = {}  -- Состояние сендов [source_track][dest_track] = true/false

-- Переменные для стерео разделения
local stereo_separation = {}  -- Стерео разделение для каждого трека [track_index] = value (0.0-1.0)
local stereo_text_show_timer = {}  -- Таймер для отображения текста [track_index] = timestamp
local stereo_text_show_duration = 2.0  -- Длительность отображения текста в секундах

-- FX Mix values [track_guid][fx_index] = value (0.0-1.0)
local fx_mix_values = {}

-- Переменные для отображения dB в сендах
local send_db_show_timer = {}  -- Таймер для отображения dB [source_track][dest_track] = timestamp
local send_db_show_duration = 2.0  -- Длительность отображения dB в секундах

-- Переменные для виртуального перетаскивания
-- Для панорамы (knob)
local knob_mouse_start_y = 0
local knob_mouse_start_value = 0
local knob_mouse_dragging = false

-- Для send level
local send_mouse_start_x = 0
local send_mouse_start_y = 0
local send_mouse_start_value = 0
local send_mouse_dragging = false
local send_mouse_dragging_track = nil  -- Отслеживаем какой именно трек перетаскивается

-- Для стерео крутилки
local stereo_mouse_start_y = 0
local stereo_mouse_start_value = 0
local stereo_mouse_dragging = false
local stereo_mouse_dragging_track = nil  -- Отслеживаем какой именно трек перетаскивается

-- Переменные для множественного выделения с Ctrl + перетаскивание
local ctrl_drag_active = false  -- Активно ли перетаскивание с Ctrl
local ctrl_drag_potential = false  -- Потенциальное перетаскивание (клик без движения)
local ctrl_drag_start_x = 0     -- Начальная позиция X для перетаскивания
local ctrl_drag_start_y = 0     -- Начальная позиция Y для перетаскивания

-- Переменная для автоскролла при перемещении треков
local track_move_autoscroll_target = nil  -- Индекс трека для автоскролла

-- Перетаскивание FX между слотами
local fx_drag_source = nil      -- Номер слота, откуда начинается перетаскивание
local fx_dragging = false       -- Активно ли перетаскивание
local fx_drag_start_x = 0       -- Начальная позиция курсора
local fx_drag_start_y = 0
local fx_click_candidate = nil  -- Слот для обычного клика (если не было движения)
local fx_hover_target = nil     -- Слот, над которым находится курсор
local target_slot_for_new_fx = nil  -- Целевой слот для нового FX из браузера
local target_track_for_new_fx = nil  -- Целевой трек для нового FX из браузера

-- Переменные для FX toggle кнопок
local fx_toggle_buttons = {}  -- Состояние кнопок для каждого трека
local fx_button_hover = {}    -- Состояние hover для кнопок

-- Переменные для контекстного меню трека
local copied_fx_data = nil  -- Данные скопированных FX
local copied_plugin_data = nil  -- Данные скопированного плагина

-- Система виртуальных слотов для FX
-- virtual_fx_slots[track_guid][virtual_slot] = real_fx_index (или nil для пустого слота)
local virtual_fx_slots = {}

-- Функция для получения виртуального маппинга для трека
local function get_virtual_mapping(track)
    if not track then return {} end
    local track_guid = reaper.GetTrackGUID(track)
    if not virtual_fx_slots[track_guid] then
        virtual_fx_slots[track_guid] = {}
    end
    return virtual_fx_slots[track_guid]
end

-- Функция для обновления виртуального маппинга на основе реальных FX
local function update_virtual_mapping(track)
    if not track then return end
    local track_guid = reaper.GetTrackGUID(track)
    local fx_count = reaper.TrackFX_GetCount(track)
    
    -- Получаем текущее маппинг
    local mapping = get_virtual_mapping(track)
    
    -- Если маппинг пустой, заполняем его последовательно
    local has_any_mapping = false
    for i = 1, 10 do
        if mapping[i] ~= nil then
            has_any_mapping = true
            break
        end
    end
    
    if not has_any_mapping then
        -- Первичная инициализация - размещаем FX последовательно
        for i = 0, fx_count - 1 do
            mapping[i + 1] = i  -- Виртуальный слот 1 = реальный FX 0, и т.д.
        end
    else
        -- Проверяем и обновляем существующее маппинг
        -- Удаляем ссылки на несуществующие FX
        for virtual_slot = 1, 10 do
            local real_fx_idx = mapping[virtual_slot]
            if real_fx_idx ~= nil and real_fx_idx >= fx_count then
                mapping[virtual_slot] = nil
            end
        end
        
        -- Добавляем новые FX в первые доступные слоты
        local used_fx = {}
        for virtual_slot = 1, 10 do
            local real_fx_idx = mapping[virtual_slot]
            if real_fx_idx ~= nil then
                used_fx[real_fx_idx] = true
            end
        end
        
        -- Находим FX которые не замаплены и добавляем их
        for real_fx_idx = 0, fx_count - 1 do
            if not used_fx[real_fx_idx] then
                -- Находим первый свободный виртуальный слот
                for virtual_slot = 1, 10 do
                    if mapping[virtual_slot] == nil then
                        mapping[virtual_slot] = real_fx_idx
                        break
                    end
                end
            end
        end
    end
end

-- Функция для перемещения FX в виртуальных слотах
local function rebuild_real_fx_order(track)
    if not track then return end
    
    local mapping = get_virtual_mapping(track)
    local fx_count = reaper.TrackFX_GetCount(track)
    
    -- Собираем информацию о всех FX
    local fx_info = {}
    for real_fx_idx = 0, fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(track, real_fx_idx, "")
        if retval then
            local enabled = reaper.TrackFX_GetEnabled(track, real_fx_idx)
            local preset_name = ""
            local retval_preset, preset = reaper.TrackFX_GetPreset(track, real_fx_idx, "")
            if retval_preset then preset_name = preset end
            
            fx_info[real_fx_idx] = {
                name = fx_name,
                enabled = enabled,
                preset = preset_name
            }
        end
    end
    
    -- Определяем желаемый порядок на основе виртуального маппинга
    local desired_order = {}
    for virtual_slot = 1, 10 do
        local real_fx_idx = mapping[virtual_slot]
        if real_fx_idx ~= nil and fx_info[real_fx_idx] then
            table.insert(desired_order, real_fx_idx)
        end
    end
    
    -- Если порядок уже правильный, ничего не делаем
    local current_order_correct = true
    for i, real_fx_idx in ipairs(desired_order) do
        if real_fx_idx ~= i - 1 then
            current_order_correct = false
            break
        end
    end
    
    if current_order_correct then return end
    
    -- Удаляем все FX (в обратном порядке чтобы индексы не сбивались)
    reaper.Undo_BeginBlock()
    for i = fx_count - 1, 0, -1 do
        reaper.TrackFX_Delete(track, i)
    end
    
    -- Добавляем FX в правильном порядке
    local new_mapping = {}
    for i, old_real_fx_idx in ipairs(desired_order) do
        local info = fx_info[old_real_fx_idx]
        if info then
            local new_fx_idx = reaper.TrackFX_AddByName(track, info.name, false, -1)
            if new_fx_idx >= 0 then
                reaper.TrackFX_SetEnabled(track, new_fx_idx, info.enabled)
                if info.preset ~= "" then
                    reaper.TrackFX_SetPreset(track, new_fx_idx, info.preset)
                end
                -- Обновляем маппинг для нового индекса
                for virtual_slot = 1, 10 do
                    if mapping[virtual_slot] == old_real_fx_idx then
                        new_mapping[virtual_slot] = new_fx_idx
                    end
                end
            end
        end
    end
    
    -- Обновляем маппинг
    local track_guid = reaper.GetTrackGUID(track)
    virtual_fx_slots[track_guid] = new_mapping
    
    reaper.Undo_EndBlock("Rebuild FX order", -1)
end

local function SyncFXChainFromSlots(track)
    -- Перестраиваем реальный порядок FX согласно virtual_fx_slots
    rebuild_real_fx_order(track)
end

local function move_fx_in_virtual_slots(track, from_virtual_slot, to_virtual_slot)
    if not track or from_virtual_slot == to_virtual_slot then 
        return false 
    end
    if to_virtual_slot < 1 or to_virtual_slot > 10 then 
        return false 
    end

    local mapping = get_virtual_mapping(track)

    -- Меняем местами содержимое слотов, включая пустые
    mapping[from_virtual_slot], mapping[to_virtual_slot] =
        mapping[to_virtual_slot], mapping[from_virtual_slot]

    -- Синхронизируем реальную FX цепь
    SyncFXChainFromSlots(track)

    return true
end

-- Функции для FX toggle кнопок
local function get_fx_state(track)
    if not track then return "none" end
    
    local fx_count = reaper.TrackFX_GetCount(track)
    if fx_count == 0 then
        return "none"  -- Нет эффектов - серая кнопка
    end
    
    -- Проверяем есть ли активные эффекты
    local has_active = false
    for i = 0, fx_count - 1 do
        if reaper.TrackFX_GetEnabled(track, i) then
            has_active = true
            break
        end
    end
    
    if has_active then
        return "active"  -- Есть активные эффекты - желтая кнопка
    else
        return "disabled"  -- Все эффекты выключены - красная кнопка
    end
end

local function toggle_track_fx(track)
    if not track then return end
    
    local fx_count = reaper.TrackFX_GetCount(track)
    if fx_count == 0 then return end  -- Нет эффектов для переключения
    
    local current_state = get_fx_state(track)
    
    reaper.Undo_BeginBlock()
    
    if current_state == "active" then
        -- Выключаем все эффекты
        for i = 0, fx_count - 1 do
            reaper.TrackFX_SetEnabled(track, i, false)
        end
    elseif current_state == "disabled" then
        -- Включаем все эффекты
        for i = 0, fx_count - 1 do
            reaper.TrackFX_SetEnabled(track, i, true)
        end
    end
    
    reaper.Undo_EndBlock("Toggle Track FX", -1)
end

local function draw_fx_toggle_button(track, track_index, x, y, size)
    if not track then return end
    
    local track_guid = reaper.GetTrackGUID(track)
    local fx_state = get_fx_state(track)
    local is_hover = fx_button_hover[track_guid] or false
    
    -- Определяем цвет кнопки
    local color
    if fx_state == "none" then
        color = 0x808080FF  -- Серый (неактивная)
    elseif fx_state == "active" then
        color = is_hover and 0xFFFF00FF or 0xFFD700FF  -- Желтый (активные FX)
    elseif fx_state == "disabled" then
        color = is_hover and 0xFF6666FF or 0xFF0000FF  -- Красный (выключенные FX)
    end
    
    -- Получаем DrawList для рисования
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Рисуем кнопку (круг)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, x + size/2, y + size/2, size/2 - 1, color)
    
    return {x = x, y = y, width = size, height = size, track = track, track_index = track_index}
end

local COLOR_SELECTED_DIM = 0x505050D0  -- Тускло-серый для выделения

-- Функция для удаления версии VST из названия плагина
local function RemoveVSTVersion(fx_name)
    if not fx_name or fx_name == "" then
        return fx_name
    end
    
    -- Удаляем различные варианты версий VST в скобках
    fx_name = fx_name:gsub(" %(VST3%)$", "")     -- Убираем " (VST3)" в конце
    fx_name = fx_name:gsub(" %(VST2%)$", "")     -- Убираем " (VST2)" в конце
    fx_name = fx_name:gsub(" %(VST%)$", "")      -- Убираем " (VST)" в конце
    fx_name = fx_name:gsub(" %(AU%)$", "")       -- Убираем " (AU)" в конце
    fx_name = fx_name:gsub(" %(DX%)$", "")       -- Убираем " (DX)" в конце
    fx_name = fx_name:gsub(" %(CLAP%)$", "")     -- Убираем " (CLAP)" в конце
    fx_name = fx_name:gsub(" %(LV2%)$", "")      -- Убираем " (LV2)" в конце
    
    -- Удаляем версии без скобок
    fx_name = fx_name:gsub(" VST3$", "")         -- Убираем " VST3" в конце
    fx_name = fx_name:gsub(" VST2$", "")         -- Убираем " VST2" в конце
    fx_name = fx_name:gsub(" VST$", "")          -- Убираем " VST" в конце
    fx_name = fx_name:gsub(" AU$", "")           -- Убираем " AU" в конце
    fx_name = fx_name:gsub(" DX$", "")           -- Убираем " DX" в конце
    fx_name = fx_name:gsub(" CLAP$", "")         -- Убираем " CLAP" в конце
    fx_name = fx_name:gsub(" LV2$", "")          -- Убираем " LV2" в конце
    
    -- Удаляем двоеточие и версии после него (например "Plugin: VST3")
    fx_name = fx_name:gsub(": VST3$", "")
    fx_name = fx_name:gsub(": VST2$", "")
    fx_name = fx_name:gsub(": VST$", "")
    fx_name = fx_name:gsub(": AU$", "")
    fx_name = fx_name:gsub(": DX$", "")
    fx_name = fx_name:gsub(": CLAP$", "")
    fx_name = fx_name:gsub(": LV2$", "")
    
    -- Удаляем префиксы типа "VST3: " или "VST: "
    fx_name = fx_name:gsub("^VST3: ", "")
    fx_name = fx_name:gsub("^VST2: ", "")
    fx_name = fx_name:gsub("^VST: ", "")
    fx_name = fx_name:gsub("^AU: ", "")
    fx_name = fx_name:gsub("^DX: ", "")
    fx_name = fx_name:gsub("^CLAP: ", "")
    fx_name = fx_name:gsub("^LV2: ", "")
    
    return fx_name
end

-- Функция для определения трека под курсором мыши
local function get_track_under_mouse(mouse_x, mouse_y, track_positions)
    for i, pos in pairs(track_positions) do
        if mouse_x >= pos.x and mouse_x <= pos.x + pos.width and
           mouse_y >= pos.y and mouse_y <= pos.y + pos.height then
            return i
        end
    end
    return nil
end

local function set_selected_track(index, ctrl_held)
    if ctrl_held then
        -- Множественное выделение с Ctrl
        local track = (index == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, index-1)
        if track then
            local is_selected = reaper.IsTrackSelected(track)
            if is_selected then
                -- Снимаем выделение с трека
                reaper.SetTrackSelected(track, false)
                selected_tracks[index] = nil
                -- Если это был основной выделенный трек, находим новый основной
                if selected_track_index == index then
                    selected_track_index = -1
                    selected_track = nil
                    -- Находим первый выделенный трек как новый основной
                    for i, _ in pairs(selected_tracks) do
                        selected_track_index = i
                        selected_track = (i == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i-1)
                        break
                    end
                end
            else
                -- Добавляем трек к выделению
                reaper.SetTrackSelected(track, true)
                reaper.CSurf_OnTrackSelection(track) -- делаем трек последним активным
                selected_tracks[index] = true
                selected_track_index = index  -- Последний выделенный становится основным
                selected_track = track
            end
        end
    else
        -- Обычное выделение (снимаем все выделения и выделяем только один трек)
        reaper.Main_OnCommand(40297, 0)  -- Снимаем все выделения
        selected_tracks = {}  -- Очищаем таблицу множественного выделения

        local track = (index == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, index-1)
        if track then
            reaper.SetOnlyTrackSelected(track)       -- также делает трек последним активным
            reaper.CSurf_OnTrackSelection(track)
            
            -- Если это мастер трек, имитируем клик по нему в основном окне REAPER
            if index == 0 then
                -- Выполняем команду "Track: Go to master track" для активации в основном окне
                reaper.Main_OnCommand(40913, 0)  -- Track: Go to master track
            end
            
            selected_track_index = index
            selected_tracks[index] = true
            selected_track = track
        end
    end
end

local function update_selected_from_reaper()
    -- Очищаем текущее состояние выделения
    selected_tracks = {}
    selected_track_index = -1
    selected_track = nil
    
    -- Проверяем мастер-трек
    local master_track = reaper.GetMasterTrack(0)
    if reaper.IsTrackSelected(master_track) then
        selected_tracks[0] = true
        selected_track_index = 0
        selected_track = master_track
    end
    
    -- Проверяем обычные треки
    local track_count = reaper.CountSelectedTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track and track ~= master_track then
            -- Находим индекс трека
            for j = 0, reaper.CountTracks(0) - 1 do
                if reaper.GetTrack(0, j) == track then
                    local track_index = j + 1
                    selected_tracks[track_index] = true
                    selected_track_index = track_index  -- Последний найденный становится основным
                    selected_track = track
                    break
                end
            end
        end
    end
    
    -- Если ничего не выделено
    if selected_track_index == -1 then
        selected_tracks = {}
        selected_track = nil
    end
end

-- Функции для контекстного меню трека
local function copy_track_fx_state(track)
    if not track then return false end
    
    local fx_count = reaper.TrackFX_GetCount(track)
    if fx_count == 0 then return false end
    
    copied_fx_data = {}
    
    for i = 0, fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(track, i, "")
        if retval then
            local enabled = reaper.TrackFX_GetEnabled(track, i)
            local preset_name = ""
            local retval_preset, preset = reaper.TrackFX_GetPreset(track, i, "")
            if retval_preset then preset_name = preset end
            
            -- Получаем состояние всех параметров
            local param_count = reaper.TrackFX_GetNumParams(track, i)
            local params = {}
            for p = 0, param_count - 1 do
                params[p] = reaper.TrackFX_GetParam(track, i, p)
            end
            
            table.insert(copied_fx_data, {
                name = fx_name,
                enabled = enabled,
                preset = preset_name,
                params = params
            })
        end
    end
    
    return true
end

local function paste_track_fx_state(track)
    if not track or not copied_fx_data then return false end
    
    reaper.Undo_BeginBlock()
    
    -- Удаляем все существующие FX
    local fx_count = reaper.TrackFX_GetCount(track)
    for i = fx_count - 1, 0, -1 do
        reaper.TrackFX_Delete(track, i)
    end
    
    -- Добавляем скопированные FX
    for _, fx_info in ipairs(copied_fx_data) do
        local new_fx_idx = reaper.TrackFX_AddByName(track, fx_info.name, false, -1)
        if new_fx_idx >= 0 then
            reaper.TrackFX_SetEnabled(track, new_fx_idx, fx_info.enabled)
            
            -- Восстанавливаем параметры
            if fx_info.params then
                for param_idx, param_value in pairs(fx_info.params) do
                    reaper.TrackFX_SetParam(track, new_fx_idx, param_idx, param_value)
                end
            end
            
            -- Устанавливаем пресет (если есть)
            if fx_info.preset and fx_info.preset ~= "" then
                reaper.TrackFX_SetPreset(track, new_fx_idx, fx_info.preset)
            end
        end
    end
    
    -- Обновляем виртуальное маппинг
    update_virtual_mapping(track)
    
    reaper.Undo_EndBlock("Paste Track FX State", -1)
    return true
end

-- Функции для копирования/вставки отдельного плагина
local function copy_plugin(track, fx_index)
    if not track or fx_index < 0 then return false end
    
    local retval, fx_name = reaper.TrackFX_GetFXName(track, fx_index, "")
    if not retval then return false end
    
    local enabled = reaper.TrackFX_GetEnabled(track, fx_index)
    local preset_name = ""
    local retval_preset, preset = reaper.TrackFX_GetPreset(track, fx_index, "")
    if retval_preset then preset_name = preset end
    
    -- Получаем состояние всех параметров
    local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
    local params = {}
    for p = 0, param_count - 1 do
        params[p] = reaper.TrackFX_GetParam(track, fx_index, p)
    end
    
    copied_plugin_data = {
        name = fx_name,
        enabled = enabled,
        preset = preset_name,
        params = params
    }
    
    return true
end

local function rename_track(track)
    if not track then return end
    
    local retval, current_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local ok, new_name = reaper.GetUserInputs("Rename Track", 1, "Track name:", current_name or "")
    
    if ok and new_name and new_name ~= "" then
        reaper.Undo_BeginBlock()
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
        reaper.Undo_EndBlock("Rename Track", -1)
    end
end

local function insert_new_track(after_track_index)
    reaper.Undo_BeginBlock()
    
    -- Вставляем новый трек после указанного индекса
    reaper.InsertTrackAtIndex(after_track_index, false)
    
    reaper.Undo_EndBlock("Insert New Track", -1)
end

local function update_track_info()
    local track_count = reaper.CountTracks(0)
    track_names[0] = "MASTER"
    track_colors[0] = 0x2A2A2AFF
    for i = 1, track_count do
        local track = reaper.GetTrack(0, i-1)
        if track then
            local _, name = reaper.GetTrackName(track, "")
            track_names[i] = name ~= "" and name or ("Track " .. i)
            local color = reaper.GetTrackColor(track)
            if color ~= 0 then
                local r = (color & 0xFF)
                local g = ((color >> 8) & 0xFF)
                local b = ((color >> 16) & 0xFF)
                track_colors[i] = (0xFF << 24) | (b << 16) | (g << 8) | r
            else
                track_colors[i] = 0x404040FF
            end
        end
    end
end

local function delete_selected_track()
    if selected_track_index <= 0 then return end  -- Не удаляем мастер-трек
    
    local track = reaper.GetTrack(0, selected_track_index - 1)
    if track then
        reaper.Undo_BeginBlock()
        reaper.DeleteTrack(track)
        reaper.Undo_EndBlock("Delete Track", -1)
        
        -- Обновляем выделение и информацию о треках
        update_selected_from_reaper()
        update_track_info()  -- Обновляем информацию о треках после удаления
    end
end

local function delete_selected_tracks()
    local tracks_to_delete = {}
    
    -- Собираем треки для удаления (исключая мастер)
    for i = 1, reaper.CountTracks(0) do
        if selected_tracks[i] then
            local track = reaper.GetTrack(0, i - 1)
            if track then
                table.insert(tracks_to_delete, track)
            end
        end
    end
    
    if #tracks_to_delete == 0 then return end
    
    reaper.Undo_BeginBlock()
    
    -- Удаляем треки в обратном порядке (чтобы индексы не сбивались)
    for i = #tracks_to_delete, 1, -1 do
        reaper.DeleteTrack(tracks_to_delete[i])
    end
    
    reaper.Undo_EndBlock("Delete Selected Tracks", -1)
    
    -- Очищаем выделение и обновляем информацию
    selected_tracks = {}
    selected_track_index = 0
    update_selected_from_reaper()
    update_track_info()
end

local function group_selected_tracks(selected_indices)
    if #selected_indices < 2 then return end
    
    -- Сортируем индексы по порядку
    table.sort(selected_indices)
    
    local first_track_idx = selected_indices[1]
    local last_track_idx = selected_indices[#selected_indices]
    
    reaper.Undo_BeginBlock()
    
    -- Делаем первый трек папкой
    local first_track = reaper.GetTrack(0, first_track_idx - 1)
    if first_track then
        reaper.SetMediaTrackInfo_Value(first_track, "I_FOLDERDEPTH", 1)
        
        -- Устанавливаем глубину для остальных треков в группе
        for i = 2, #selected_indices do
            local track_idx = selected_indices[i]
            local track = reaper.GetTrack(0, track_idx - 1)
            if track then
                if i == #selected_indices then
                    -- Последний трек в группе - закрываем папку
                    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", -1)
                else
                    -- Промежуточные треки - обычная глубина
                    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
                end
            end
        end
        
        -- Добавляем визуальные разделители (spacers)
        -- Spacer перед группой
        local spacer_before = reaper.InsertTrackAtIndex(first_track_idx - 1, false)
        reaper.GetSetMediaTrackInfo_String(spacer_before, "P_NAME", "--- GROUP SPACER ---", true)
        reaper.SetMediaTrackInfo_Value(spacer_before, "B_SHOWINTCP", 0) -- Скрываем в TCP
        reaper.SetMediaTrackInfo_Value(spacer_before, "B_SHOWINMIXER", 0) -- Скрываем в микшере
        
        -- Spacer после группы (нужно пересчитать индекс из-за вставки)
        local spacer_after = reaper.InsertTrackAtIndex(last_track_idx + 1, false)
        reaper.GetSetMediaTrackInfo_String(spacer_after, "P_NAME", "--- GROUP SPACER ---", true)
        reaper.SetMediaTrackInfo_Value(spacer_after, "B_SHOWINTCP", 0) -- Скрываем в TCP
        reaper.SetMediaTrackInfo_Value(spacer_after, "B_SHOWINMIXER", 0) -- Скрываем в микшере
    end
    
    reaper.Undo_EndBlock("Group Selected Tracks", -1)
    
    -- Обновляем выделение и информацию
    update_selected_from_reaper()
    update_track_info()
end

local function draw_track_context_menu(track_index, track)
    if not track then return end

    -- Подсчитываем количество выделенных треков (исключая мастер)
    local selected_count = 0
    local selected_indices = {}
    for i = 1, reaper.CountTracks(0) do
        if selected_tracks[i] then
            selected_count = selected_count + 1
            table.insert(selected_indices, i)
        end
    end

    -- Если выделено несколько треков, показываем групповое меню
    if selected_count > 1 then
        reaper.ImGui_Text(ctx, "Selected tracks: " .. selected_count)
        reaper.ImGui_Separator(ctx)

        if reaper.ImGui_MenuItem(ctx, "Delete selected") then
            delete_selected_tracks()
        end

        if reaper.ImGui_MenuItem(ctx, "Group selected") then
            group_selected_tracks(selected_indices)
        end

        return
    end

    -- Обычное меню для одного трека
    local retval, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    local display_name = (track_name and track_name ~= "") and track_name or
                         (track_index == 0 and "MASTER" or ("Track " .. track_index))

    reaper.ImGui_Text(ctx, display_name)
    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_MenuItem(ctx, "Rename track") then
        rename_track(track)
    end

    if reaper.ImGui_MenuItem(ctx, "Track color") then
        -- Вызываем стандартное окно выбора цвета Reaper
        reaper.Main_OnCommand(40357, 0)  -- Track: Set track(s) to custom color
    end

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_MenuItem(ctx, "Copy track state") then
        copy_track_fx_state(track)
    end

    local can_paste = copied_fx_data ~= nil
    if can_paste then
        if reaper.ImGui_MenuItem(ctx, "Paste track state") then
            paste_track_fx_state(track)
        end
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
        reaper.ImGui_MenuItem(ctx, "Paste track state", nil, false, false)
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_Separator(ctx)

    if track_index > 0 then
        if reaper.ImGui_MenuItem(ctx, "Insert new track") then
            insert_new_track(track_index)
        end
    end

    if reaper.ImGui_MenuItem(ctx, "Insert multiple tracks") then
        -- Команда для диалога вставки треков
        reaper.Main_OnCommand(41067, 0)
    end

    reaper.ImGui_Separator(ctx)

    if track_index > 0 then
        if reaper.ImGui_MenuItem(ctx, "Delete") then
            delete_selected_track()
        end
    end
end

local CHANNEL_WIDTH = 47  -- Уменьшено на 17 пикселей (было 64)
local MASTER_WIDTH = 84
local MIN_CHANNEL_HEIGHT = 350  -- Уменьшено с 380 до 350 для сокращения высоты треков на 30 пикселей
local MIN_MASTER_HEIGHT = 370   -- Уменьшено с 400 до 370 для сокращения высоты мастер-трека на 30 пикселей
local SLIDER_WIDTH = 20
local KNOB_SIZE = 32  -- Увеличиваем размер панорамы
local SMALL_KNOB_SIZE = 20  -- Размер маленькой крутилки для стерео разделения
local ICON_SIZE = 20

local COLOR_ACTIVE = 0x91FF33FF
local COLOR_ARROW = 0x91FF33FF
local COLOR_TRIANGLE = 0x606060FF
local COLOR_INACTIVE = 0x3A3A3AFF
local COLOR_SIDECHAIN = 0xFF8C00FF
local COLOR_BG = 0x1E1E1EFF
local COLOR_SELECTED = 0x0A7AFFFF
local COLOR_BUTTON = 0x303030FF
local COLOR_BUTTON_HOVER = 0x404040FF
local COLOR_BUTTON_ACTIVE = 0x505050FF
local COLOR_TEXT = 0xC0C0C0FF
local COLOR_FADER = 0x404040FF


local COLOR_LAMP_GREEN = 0xA4FF54FF
local COLOR_LAMP_GRAY = 0x373C40FF
local COLOR_LAMP_OUTLINE = 0x181C1EFF

local function simple_lamp_button(ctx, id, size, on)
    local pos_x, pos_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = pos_x + size/2, pos_y + size/2
    local outline = COLOR_LAMP_OUTLINE
    local color = on and COLOR_LAMP_GREEN or COLOR_LAMP_GRAY
    reaper.ImGui_InvisibleButton(ctx, id, size, size)
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, size/2, color, 32)
    reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, size/2-1.1, outline, 32, 1.9)
    if on then
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx-size/4, cy-size/4, size/5, 0xFFFFFFFF, 12)
    end
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local is_lclicked = reaper.ImGui_IsItemClicked(ctx, 0)
    local is_rclicked = reaper.ImGui_IsItemClicked(ctx, 1)
    
    return is_lclicked, is_rclicked
end

local function solo_on(idx)
    for i = 1, reaper.CountTracks(0) do
        local tr = reaper.GetTrack(0, i-1)
        if i == idx then
            reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
            reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 2)
        else
            reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
            reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 0)
        end
    end
end

local function solo_off()
    for i = 1, reaper.CountTracks(0) do
        local tr = reaper.GetTrack(0, i-1)
        reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
        reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 0)
    end
end

local function fl_button(ctx, label, size_x, size_y, color)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), color or COLOR_BUTTON)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLOR_BUTTON_HOVER)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLOR_BUTTON_ACTIVE)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLOR_TEXT)
    local result = reaper.ImGui_Button(ctx, label, size_x, size_y)
    reaper.ImGui_PopStyleColor(ctx, 4)
    return result
end

local function simple_knob_pan(ctx, label, value, min, max, size, color)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local pos_x, pos_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local center_x = pos_x + size / 2
    local center_y = pos_y + size / 2
    local radius = size / 2 - 4  -- Увеличиваем внутренний круг (было -6)
    local track_radius = radius + 3  -- Уменьшаем окантовку (было +4, стало +3)

    reaper.ImGui_InvisibleButton(ctx, label, size, size)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    
    -- Проверяем правый клик для контекстного меню
    local right_clicked = is_hovered and reaper.ImGui_IsMouseClicked(ctx, 1)
    
    -- Виртуальное перетаскивание с правильной логикой
    local new_value = value
    local mouse_changed = false
    
    -- Начинаем перетаскивание только при первом нажатии
    if reaper.ImGui_IsItemActive(ctx) and not knob_mouse_dragging then
        knob_mouse_dragging = true
        knob_mouse_start_y = select(2, reaper.GetMousePosition())
        knob_mouse_start_value = value
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Обновляем значение во время перетаскивания
    if knob_mouse_dragging and reaper.ImGui_IsItemActive(ctx) then
        local _, my = reaper.GetMousePosition()
        local dy = my - knob_mouse_start_y
        local sensitivity = (max - min) / 1500  -- Чувствительность уменьшена в 3 раза
        new_value = knob_mouse_start_value - dy * sensitivity
        new_value = math.max(min, math.min(max, new_value))
        mouse_changed = true
        
        -- Возвращаем мышь обратно к стартовой позиции
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Заканчиваем перетаскивание при отпускании мыши
    if knob_mouse_dragging and not reaper.ImGui_IsMouseDown(ctx, 0) then
        knob_mouse_dragging = false
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
    end

    -- Рисуем основной круг (темно-серый фон) - больше размер
    local bg_color = is_hovered and 0x3A3A3AFF or 0x2A2A2AFF
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, radius, bg_color, 32)
    
    -- Рисуем более контрастную окантовку (трек для индикатора) - уже толщина
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, track_radius, 0x606060FF, 32, 3)  -- Более светлый серый (было 0x404040FF)
    
    -- Определяем цвет индикатора в зависимости от значения панорамы
    local indicator_color
    if math.abs(value) < 0.05 then
        -- Центр - серый цвет
        indicator_color = 0x808080FF
    elseif value < 0 then
        -- Левая панорама - оранжевый цвет
        indicator_color = 0xFF8000FF
    else
        -- Правая панорама - красный цвет
        indicator_color = 0xFF4000FF
    end

    -- Рисуем дугу-индикатор на окантовке (как в прошлом скрипте)
    if math.abs(value) > 0.01 then
        -- Вычисляем углы для дуги
        local start_angle = -math.pi / 2  -- Начинаем сверху (12 часов)
        local end_angle = start_angle + (value * math.pi)  -- Заканчиваем в зависимости от значения
        
        -- Рисуем дугу-индикатор
        reaper.ImGui_DrawList_PathArcTo(draw_list, center_x, center_y, track_radius, start_angle, end_angle, 32)
        reaper.ImGui_DrawList_PathStroke(draw_list, indicator_color, 0, 5)  -- Немного тоньше дуга (было 6, стало 5)
    end

    -- Обработка взаимодействия с уменьшенной чувствительностью
    local wheel_changed = false
    
    if is_hovered and wheel ~= 0 then
        new_value = value + wheel * 0.02
        new_value = math.max(min, math.min(max, new_value))
        wheel_changed = true
    end

    -- Отображение текста
    reaper.ImGui_PushFont(ctx, font_small)
    local text = ""
    if new_value <= -0.98 then
        text = "L100"
    elseif new_value >= 0.98 then
        text = "R100"
    elseif math.abs(new_value) < 0.01 then
        text = "C"
    elseif new_value < 0 then
        text = string.format("L%.0f", math.abs(new_value * 100))
    else
        text = string.format("R%.0f", new_value * 100)
    end
    local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, text)
    reaper.ImGui_SetCursorScreenPos(ctx, center_x - text_w / 2, center_y + track_radius + 8)
    reaper.ImGui_TextColored(ctx, COLOR_TEXT, text)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, pos_x, pos_y + size + 20)

    return mouse_changed, new_value, right_clicked
end

-- Функция для крутилки панорамы с абсолютным позиционированием
local function simple_knob_pan_absolute(ctx, label, value, min, max, size, color, screen_x, screen_y)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local center_x = screen_x + size / 2
    local center_y = screen_y + size / 2
    local radius = size / 2 - 4  -- Увеличиваем внутренний круг (было -6)
    local track_radius = radius + 3  -- Уменьшаем окантовку (было +4, стало +3)

    reaper.ImGui_SetCursorScreenPos(ctx, screen_x, screen_y)
    reaper.ImGui_InvisibleButton(ctx, label, size, size)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    
    -- Проверяем правый клик для контекстного меню
    local right_clicked = is_hovered and reaper.ImGui_IsMouseClicked(ctx, 1)
    
    -- Виртуальное перетаскивание с правильной логикой
    local new_value = value
    local mouse_changed = false
    
    -- Начинаем перетаскивание только при первом нажатии
    if reaper.ImGui_IsItemActive(ctx) and not knob_mouse_dragging then
        knob_mouse_dragging = true
        knob_mouse_start_y = select(2, reaper.GetMousePosition())
        knob_mouse_start_value = value
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Обновляем значение во время перетаскивания
    if knob_mouse_dragging and reaper.ImGui_IsItemActive(ctx) then
        local _, my = reaper.GetMousePosition()
        local dy = my - knob_mouse_start_y
        local sensitivity = (max - min) / 1500  -- Чувствительность уменьшена в 3 раза
        new_value = knob_mouse_start_value - dy * sensitivity
        new_value = math.max(min, math.min(max, new_value))
        mouse_changed = true
        
        -- Возвращаем мышь обратно к стартовой позиции
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Заканчиваем перетаскивание при отпускании мыши
    if knob_mouse_dragging and not reaper.ImGui_IsMouseDown(ctx, 0) then
        knob_mouse_dragging = false
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
    end

    -- Рисуем основной круг (темно-серый фон) - больше размер
    local bg_color = is_hovered and 0x3A3A3AFF or 0x2A2A2AFF
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, radius, bg_color, 32)
    
    -- Рисуем более контрастную окантовку (трек для индикатора) - уже толщина
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, track_radius, 0x606060FF, 32, 3)  -- Более светлый серый (было 0x404040FF)
    
    -- Определяем цвет индикатора в зависимости от значения панорамы
    local indicator_color
    if math.abs(value) < 0.05 then
        -- Центр - серый цвет
        indicator_color = 0x808080FF
    elseif value < 0 then
        -- Левая панорама - оранжевый цвет
        indicator_color = 0xFF8000FF
    else
        -- Правая панорама - красный цвет
        indicator_color = 0xFF4000FF
    end

    -- Рисуем дугу-индикатор на окантовке (как в прошлом скрипте)
    if math.abs(value) > 0.01 then
        -- Вычисляем углы для дуги
        local start_angle = -math.pi / 2  -- Начинаем сверху (12 часов)
        local end_angle = start_angle + (value * math.pi)  -- Заканчиваем в зависимости от значения
        
        -- Рисуем дугу-индикатор
        reaper.ImGui_DrawList_PathArcTo(draw_list, center_x, center_y, track_radius, start_angle, end_angle, 32)
        reaper.ImGui_DrawList_PathStroke(draw_list, indicator_color, 0, 5)  -- Немного тоньше дуга (было 6, стало 5)
    end

    -- Обработка взаимодействия с уменьшенной чувствительностью
    local wheel_changed = false
    
    if is_hovered and wheel ~= 0 then
        new_value = value + wheel * 0.02
        new_value = math.max(min, math.min(max, new_value))
        wheel_changed = true
    end

    -- Отображение текста внутри круга только во время манипуляций
    if is_active or is_hovered then
        reaper.ImGui_PushFont(ctx, font_small)
        local text = ""
        if new_value <= -0.98 then
            text = "L100"
        elseif new_value >= 0.98 then
            text = "R100"
        elseif math.abs(new_value) < 0.01 then
            text = "C"
        elseif new_value < 0 then
            text = string.format("L%.0f", math.abs(new_value * 100))
        else
            text = string.format("R%.0f", new_value * 100)
        end
        local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, text)
        -- Отображаем текст в центре крутилки (внутри круга)
        reaper.ImGui_DrawList_AddText(draw_list, center_x - text_w / 2, center_y - text_h / 2, COLOR_TEXT, text)
        reaper.ImGui_PopFont(ctx)
    end

    return mouse_changed, new_value, right_clicked
end

-- Функция для маленькой крутилки стерео разделения
local function small_stereo_separation_knob(ctx, screen_x, screen_y, size, value, min, max, track_id, show_text)
    local center_x = screen_x + size / 2
    local center_y = screen_y + size / 2
    local radius = size / 2 - 2
    local track_radius = radius + 1  -- Радиус канавки
    
    reaper.ImGui_SetCursorScreenPos(ctx, screen_x, screen_y)
    reaper.ImGui_InvisibleButton(ctx, "stereo_sep_" .. track_id, size, size)
    
    local is_active = reaper.ImGui_IsItemActive(ctx)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local is_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
    local wheel = 0
    if is_hovered then
        wheel = reaper.ImGui_GetMouseWheel(ctx)
    end
    
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Фон крутилки (темно-серый круг как у панорамы)
    local bg_color = is_hovered and 0x3A3A3AFF or 0x2A2A2AFF
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, radius, bg_color, 32)
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, radius, 0x606060FF, 32, 1)
    
    -- Канавка (темная дорожка) - полный круг
    local track_thickness = 1  -- Сделали тоньше (было 2)
    local segments = 32
    
    for i = 0, segments do
        local angle1 = (i / segments) * 2 * math.pi
        local angle2 = ((i + 1) / segments) * 2 * math.pi
        
        local x1_outer = center_x + math.cos(angle1) * (track_radius + track_thickness)
        local y1_outer = center_y + math.sin(angle1) * (track_radius + track_thickness)
        local x1_inner = center_x + math.cos(angle1) * track_radius
        local y1_inner = center_y + math.sin(angle1) * track_radius
        
        local x2_outer = center_x + math.cos(angle2) * (track_radius + track_thickness)
        local y2_outer = center_y + math.sin(angle2) * (track_radius + track_thickness)
        local x2_inner = center_x + math.cos(angle2) * track_radius
        local y2_inner = center_y + math.sin(angle2) * track_radius
        
        -- Темная канавка
        reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
            x1_outer, y1_outer, x2_outer, y2_outer, 
            x2_inner, y2_inner, x1_inner, y1_inner, 
            0x404040FF)
    end
    
    -- Определяем режим: separated (0-0.5) или merged (0.5-1)
    local is_separated_mode = value < 0.5
    local mode_value = is_separated_mode and (0.5 - value) * 2 or (value - 0.5) * 2  -- 0-1 в каждом режиме
    
    -- Цвета для режимов
    local separated_color = 0x00BFFFFF  -- Голубой
    local merged_color = 0x8A2BE2FF    -- Фиолетовый
    local current_color = is_separated_mode and separated_color or merged_color
    
    -- Рисуем активную дугу в зависимости от режима
    if is_separated_mode then
        -- Separated: от 12 часов до 6 часов против часовой стрелки (левая половина)
        local start_angle = -math.pi / 2  -- 12 часов
        local end_angle = start_angle - mode_value * math.pi  -- До 6 часов против часовой
        
        local active_segments = math.floor(segments * mode_value / 2)  -- Половина сегментов для половины круга
        for i = 0, active_segments do
            local progress = i / (segments / 2)  -- Нормализуем для половины круга
            if progress > mode_value then break end
            
            local angle1 = start_angle - progress * math.pi
            local angle2 = start_angle - math.min((i + 1) / (segments / 2), mode_value) * math.pi
            
            local x1_outer = center_x + math.cos(angle1) * (track_radius + track_thickness)
            local y1_outer = center_y + math.sin(angle1) * (track_radius + track_thickness)
            local x1_inner = center_x + math.cos(angle1) * track_radius
            local y1_inner = center_y + math.sin(angle1) * track_radius
            
            local x2_outer = center_x + math.cos(angle2) * (track_radius + track_thickness)
            local y2_outer = center_y + math.sin(angle2) * (track_radius + track_thickness)
            local x2_inner = center_x + math.cos(angle2) * track_radius
            local y2_inner = center_y + math.sin(angle2) * track_radius
            
            reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
                x1_outer, y1_outer, x2_outer, y2_outer, 
                x2_inner, y2_inner, x1_inner, y1_inner, 
                separated_color)
        end
    else
        -- Merged: от 12 часов до 6 часов по часовой стрелке (правая половина)
        local start_angle = -math.pi / 2  -- 12 часов
        local end_angle = start_angle + mode_value * math.pi  -- До 6 часов по часовой
        
        local active_segments = math.floor(segments * mode_value / 2)  -- Половина сегментов для половины круга
        for i = 0, active_segments do
            local progress = i / (segments / 2)  -- Нормализуем для половины круга
            if progress > mode_value then break end
            
            local angle1 = start_angle + progress * math.pi
            local angle2 = start_angle + math.min((i + 1) / (segments / 2), mode_value) * math.pi
            
            local x1_outer = center_x + math.cos(angle1) * (track_radius + track_thickness)
            local y1_outer = center_y + math.sin(angle1) * (track_radius + track_thickness)
            local x1_inner = center_x + math.cos(angle1) * track_radius
            local y1_inner = center_y + math.sin(angle1) * track_radius
            
            local x2_outer = center_x + math.cos(angle2) * (track_radius + track_thickness)
            local y2_outer = center_y + math.sin(angle2) * (track_radius + track_thickness)
            local x2_inner = center_x + math.cos(angle2) * track_radius
            local y2_inner = center_y + math.sin(angle2) * track_radius
            
            reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
                x1_outer, y1_outer, x2_outer, y2_outer, 
                x2_inner, y2_inner, x1_inner, y1_inner, 
                merged_color)
        end
    end
    
    -- Отображаем текст в центре крутилки только при взаимодействии
    if show_text then
        reaper.ImGui_PushFont(ctx, font_micro)
        local text = ""
        if is_separated_mode then
            text = string.format("S%.0f", mode_value * 100)
        else
            text = string.format("M%.0f", mode_value * 100)
        end
        local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, text)
        local text_x = center_x - text_w / 2
        local text_y = center_y - text_h / 2
        reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, 0xFFFFFFFF, text)
        reaper.ImGui_PopFont(ctx)
    end
    
    local new_value = value
    local mouse_changed = false
    local wheel_changed = false
    local right_clicked = false
    
    -- Обработка правого клика
    if is_hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
        right_clicked = true
    end
    
    -- Виртуальное перетаскивание с правильной логикой
    -- Начинаем перетаскивание только при первом нажатии
    if is_active and not stereo_mouse_dragging then
        stereo_mouse_dragging = true
        stereo_mouse_dragging_track = track_id
        stereo_mouse_start_y = select(2, reaper.GetMousePosition())
        stereo_mouse_start_value = value
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Обновляем значение во время перетаскивания
    if stereo_mouse_dragging and stereo_mouse_dragging_track == track_id and is_active then
        local _, my = reaper.GetMousePosition()
        local dy = my - stereo_mouse_start_y
        local sensitivity = (max - min) / 1500  -- Чувствительность как у панорамы
        new_value = stereo_mouse_start_value - dy * sensitivity
        new_value = math.max(min, math.min(max, new_value))
        mouse_changed = true
        
        -- Скрываем курсор во время перетаскивания
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
    end
    
    -- Заканчиваем перетаскивание при отпускании мыши
    if stereo_mouse_dragging and stereo_mouse_dragging_track == track_id and not reaper.ImGui_IsMouseDown(ctx, 0) then
        stereo_mouse_dragging = false
        stereo_mouse_dragging_track = nil
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
    end
    
    -- Обработка мыши (клик для быстрого изменения)
    if is_clicked and not stereo_mouse_dragging then
        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
        local dx = mouse_x - center_x
        local dy = mouse_y - center_y
        local angle = math.atan(dy, dx)
        
        -- Определяем, в какой половине круга клик
        if angle >= -math.pi / 2 and angle <= math.pi / 2 then
            -- Правая половина (merged mode)
            local progress = (angle + math.pi / 2) / math.pi  -- 0-1
            new_value = 0.5 + progress * 0.5
        else
            -- Левая половина (separated mode)
            if angle < -math.pi / 2 then
                angle = angle + 2 * math.pi  -- Нормализуем угол
            end
            local progress = (angle - math.pi / 2) / math.pi  -- 0-1
            new_value = 0.5 - progress * 0.5
        end
        new_value = math.max(min, math.min(max, new_value))
        mouse_changed = true
    end
    
    -- Обработка колесика мыши
    if is_hovered and wheel ~= 0 then
        new_value = value + wheel * 0.02
        new_value = math.max(min, math.min(max, new_value))
        wheel_changed = true
    end
    
    return mouse_changed or wheel_changed, new_value, right_clicked
end

-- Функция для рисования улучшенной крутилки Mix (0-100%)
local function small_mix_knob(ctx, x, y, size, value, min, max, id)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    
    -- Используем PushID для уникальности элемента
    reaper.ImGui_PushID(ctx, id)
    
    -- Получаем текущую позицию курсора в layout
    local cursor_pos_x, cursor_pos_y = reaper.ImGui_GetCursorPos(ctx)
    
    -- Создаем невидимую кнопку в текущем layout (не используем SetCursorScreenPos)
    reaper.ImGui_InvisibleButton(ctx, "MixBtn", size, size)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    
    -- Получаем экранные координаты кнопки для рендеринга
    local button_screen_x, button_screen_y = reaper.ImGui_GetItemRectMin(ctx)
    local center_x = button_screen_x + size / 2
    local center_y = button_screen_y + size / 2
    local outer_radius = size / 2 - 1
    local inner_radius = outer_radius - 4
    local track_radius = outer_radius - 2
    
    local mouse_changed = false
    local wheel_changed = false
    local right_clicked = false
    local new_value = value
    
    -- Обработка правого клика
    if is_hovered and reaper.ImGui_IsMouseClicked(ctx, 1) then
        right_clicked = true
    end
    
    -- Обработка мыши
    if is_active and reaper.ImGui_IsMouseDragging(ctx, 0) then
        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
        local dx = mouse_x - center_x
        local dy = mouse_y - center_y
        local angle = math.atan(dy, dx)
        
        -- Преобразуем угол в значение (0-1), начинаем с 6 часов (внизу) и идем по часовой стрелке
        local normalized_angle = (angle + math.pi * 0.5) % (2 * math.pi)
        local progress = normalized_angle / (2 * math.pi)  -- Полный круг для диапазона 0-100%
        progress = math.max(0, math.min(1, progress))
        
        new_value = min + progress * (max - min)
        new_value = math.max(min, math.min(max, new_value))
        mouse_changed = true
    end
    
    -- Обработка колесика мыши
    if is_hovered then
        local wheel_delta = reaper.ImGui_GetMouseWheel(ctx)
        if wheel_delta ~= 0 then
            new_value = value + wheel_delta * 0.01 * (max - min)
            new_value = math.max(min, math.min(max, new_value))
            wheel_changed = true
        end
    end
    
    -- Рисуем канавку (track) - темная окружность
    local track_color = 0x1A1A1AFF
    local track_thickness = 3
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, track_radius, track_color, 64, track_thickness)
    
    -- Рисуем активную часть канавки (индикатор прогресса)
    local normalized = (value - min) / (max - min)
    if normalized > 0.01 then
        local segments = 48
        local start_angle = math.pi * 0.5  -- Начинаем с 6 часов (внизу)
        local sweep_angle = normalized * 2 * math.pi  -- Полный круг для 100%
        
        for i = 0, segments - 1 do
            local t1 = i / segments
            local t2 = (i + 1) / segments
            
            if t2 <= normalized then
                local angle1 = start_angle + t1 * 2 * math.pi
                local angle2 = start_angle + t2 * 2 * math.pi
                
                local x1 = center_x + math.cos(angle1) * track_radius
                local y1 = center_y + math.sin(angle1) * track_radius
                local x2 = center_x + math.cos(angle2) * track_radius
                local y2 = center_y + math.sin(angle2) * track_radius
                
                -- Градиент от синего к зеленому в зависимости от значения
                local color_factor = t1
                local r = math.floor(10 + color_factor * 100)
                local g = math.floor(122 + color_factor * 133)
                local b = math.floor(255 - color_factor * 100)
                local color = (r << 24) | (g << 16) | (b << 8) | 0xFF
                
                reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, color, (track_thickness + 1) / 2)
            end
        end
    end
    
    -- Рисуем основной круг ручки (центральная часть)
    local knob_color = is_hovered and 0x4A4A4AFF or 0x3A3A3AFF
    local knob_border_color = is_active and 0x0A7AFFFF or 0x606060FF
    
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, inner_radius, knob_color, 32)
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, inner_radius, knob_border_color, 32, 1.5)
    
    -- Отображаем значение в процентах при hover
    if is_hovered then
        local percentage = math.floor(normalized * 100 + 0.5)
        local text = tostring(percentage) .. "%"
        local text_size_x, text_size_y = reaper.ImGui_CalcTextSize(ctx, text)
        local text_x = center_x - text_size_x / 2
        local text_y = center_y + outer_radius + 5
        
        -- Фон для текста
        reaper.ImGui_DrawList_AddRectFilled(draw_list, 
            text_x - 2, text_y - 1, 
            text_x + text_size_x + 2, text_y + text_size_y + 1, 
            0x000000CC, 2)
        
        -- Текст
        reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, 0xFFFFFFFF, text)
    end
    
    -- Контекстное меню для mix knob
    if reaper.ImGui_BeginPopupContextItem(ctx, "MixContext") then
        if reaper.ImGui_MenuItem(ctx, "Reset Mix") then
            new_value = 0.5  -- Сброс к 50%
            mouse_changed = true
        end
        
        if reaper.ImGui_MenuItem(ctx, "Copy Value") then
            copied_mix = value
        end
        
        -- Paste Value - активно только если есть скопированное значение
        if copied_mix then
            if reaper.ImGui_MenuItem(ctx, "Paste Value") then
                new_value = copied_mix
                mouse_changed = true
            end
        else
            -- Неактивный пункт меню
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
            reaper.ImGui_MenuItem(ctx, "Paste Value", nil, false, false)
            reaper.ImGui_PopStyleColor(ctx)
        end
        
        reaper.ImGui_EndPopup(ctx)
    end
    
    reaper.ImGui_PopID(ctx)
    
    return mouse_changed or wheel_changed, new_value, right_clicked
end

-- Функция для лампочки с абсолютным позиционированием
local function simple_lamp_button_absolute(ctx, label, on, screen_x, screen_y, size)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local center_x = screen_x + size / 2
    local center_y = screen_y + size / 2
    local outline = COLOR_LAMP_OUTLINE
    local color = on and COLOR_LAMP_GREEN or COLOR_LAMP_GRAY

    reaper.ImGui_SetCursorScreenPos(ctx, screen_x, screen_y)
    reaper.ImGui_InvisibleButton(ctx, label, size, size)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local is_lclicked = reaper.ImGui_IsItemClicked(ctx, 0)
    local is_rclicked = reaper.ImGui_IsItemClicked(ctx, 1)

    -- Рисуем основной круг
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x, center_y, size/2, color, 32)
    
    -- Рисуем контур
    reaper.ImGui_DrawList_AddCircle(draw_list, center_x, center_y, size/2-1.1, outline, 32, 1.9)
    
    -- Рисуем белую точку если лампочка включена
    if on then
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, center_x-size/4, center_y-size/4, size/5, 0xFFFFFFFF, 12)
    end

    return is_lclicked, is_rclicked
end

local function track_has_send(track_src, track_dest)
    for i = 0, reaper.GetTrackNumSends(track_src, 0)-1 do
        if reaper.GetTrackSendInfo_Value(track_src, 0, i, 'P_DESTTRACK') == track_dest then
            if reaper.GetTrackSendInfo_Value(track_src, 0, i, "I_SENDCHAN") ~= 2 then
                return i
            end
        end
    end
    return nil
end

local function track_has_sidechain(track_src, track_dest)
    for i = 0, reaper.GetTrackNumSends(track_src, 0)-1 do
        if reaper.GetTrackSendInfo_Value(track_src, 0, i, 'P_DESTTRACK') == track_dest then
            local ch = reaper.GetTrackSendInfo_Value(track_src, 0, i, "I_SRCCHAN")
            if ch == 2 then return i end
        end
    end
    return nil
end

local function track_routed_to_master(track)
    if not track or track == reaper.GetMasterTrack(0) then
        return false
    end
    return reaper.GetMediaTrackInfo_Value(track, 'B_MAINSEND') == 1
end

-- Функция для обновления данных посылов после перемещения треков
local function update_send_data_after_track_move()
    -- Очищаем только индексные таблицы (GUID таблицы сохраняем)
    send_levels = {}
    send_states = {}
    
    -- Получаем количество треков в проекте
    local track_count = reaper.CountTracks(0)
    
    -- Восстанавливаем индексные таблицы из GUID таблиц
    for i = 0, track_count - 1 do
        local source_track = reaper.GetTrack(0, i)
        if source_track then
            local source_guid = reaper.GetTrackGUID(source_track)
            
            -- Проверяем, есть ли данные для этого трека в GUID таблице
            if send_levels_by_guid[source_guid] then
                for dest_guid, level in pairs(send_levels_by_guid[source_guid]) do
                    -- Находим трек назначения по GUID
                    for j = 0, track_count - 1 do
                        local dest_track = reaper.GetTrack(0, j)
                        if dest_track and reaper.GetTrackGUID(dest_track) == dest_guid then
                            -- Восстанавливаем данные в индексных таблицах
                            if not send_levels[i + 1] then send_levels[i + 1] = {} end
                            if not send_states[i + 1] then send_states[i + 1] = {} end
                            
                            send_levels[i + 1][j + 1] = level
                            send_states[i + 1][j + 1] = send_states_by_guid[source_guid][dest_guid] or true
                            break
                        end
                    end
                end
                
                -- Устанавливаем курсор на следующую позицию точно без промежутков
                if slot < 10 then
                    local next_y = cursor_y + slot_height
                    reaper.ImGui_SetCursorPos(ctx, cursor_x, next_y)
                end
            end
        end
    end
end

local function draw_triangle_down(draw_list, cx, cy, size, color)
    local h = size * 0.6
    reaper.ImGui_DrawList_AddTriangleFilled(
        draw_list,
        cx - size/2, cy - h/2,
        cx + size/2, cy - h/2,
        cx, cy + h/2,
        color
    )
end

local function draw_triangle_up(draw_list, cx, cy, size, color)
    local h = size * 0.6
    reaper.ImGui_DrawList_AddTriangleFilled(
        draw_list,
        cx - size/2, cy + h/2,
        cx + size/2, cy + h/2,
        cx, cy - h/2,
        color
    )
end

local function draw_triangle_down(draw_list, cx, cy, size, color)
    local h = size * 0.6
    reaper.ImGui_DrawList_AddTriangleFilled(
        draw_list,
        cx - size/2, cy - h/2,
        cx + size/2, cy - h/2,
        cx, cy + h/2,
        color
    )
end

local function draw_circle_arrow(draw_list, cx, cy, size, color)
    local r = size/2 - 2
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, r, 0x1A1A1AFF, 24)
    reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, r, color, 32, 2)
    draw_triangle_up(draw_list, cx, cy - r + 6, ICON_SIZE * 0.3, color)  -- Используем исходный размер ICON_SIZE
end

local function draw_circle_arrow_big(draw_list, cx, cy, size, color)
    local r = size/2 - 2
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, r, 0x1A1A1AFF, 24)
    reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, r, color, 32, 3)
    draw_triangle_up(draw_list, cx, cy - r + 7, ICON_SIZE * 0.4, color)  -- Используем исходный размер ICON_SIZE
end

-- Функция для рисования круга сенда в стиле панорамы с дуговым слайдером
local function draw_send_ring_control(ctx, cx, cy, size, send_level, has_send, is_triangle_hovered, is_circle_hovered, show_db)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local radius = size/2 - 2  -- Радиус как у панорамы
    
    if has_send then
        -- Если hover треугольника, рисуем контур вокруг всей области (круг + шеврон)
        if is_triangle_hovered then
            local arrow_height = radius * 0.5
            local arrow_half_base = arrow_height * 0.9
            local arrow_top_y = cy - radius - arrow_height - 5
            local hover_outline_color = COLOR_ACTIVE
            local outline_thickness = 2
            local outline_offset = 8
            
            -- Создаем массив точек контура по часовой стрелке
            local points = {}
            
            -- 1. Вершина треугольника (верх)
            table.insert(points, {cx, arrow_top_y - outline_offset})
            
            -- 2-N. Точки дуги (по часовой стрелке) - начинаем и заканчиваем в точках соединения
            local arc_segments = 24
            local start_angle = -math.pi * 0.3  -- Начинаем справа вверху
            local end_angle = math.pi + math.pi * 0.3  -- Заканчиваем слева вверху
            
            for i = 0, arc_segments do
                local angle = start_angle + (i / arc_segments) * (end_angle - start_angle)
                local x = cx + math.cos(angle) * (radius + outline_offset)
                local y = cy + math.sin(angle) * (radius + outline_offset)
                table.insert(points, {x, y})
            end
            
            -- Рисуем контур, соединяя точки по порядку
            for i = 1, #points do
                local current_point = points[i]
                local next_point = points[i % #points + 1]  -- Замыкаем на первую точку
                
                reaper.ImGui_DrawList_AddLine(draw_list, 
                    current_point[1], current_point[2],
                    next_point[1], next_point[2],
                    hover_outline_color, outline_thickness)
            end
        end
        -- Рисуем основной круг (темно-серый фон) как у панорамы
        local bg_color = is_circle_hovered and 0x3A3A3AFF or 0x2A2A2AFF
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, bg_color, 32)
        
        -- Рисуем окантовку круга как у панорамы
        reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, 0x606060FF, 32, 1.5)
        
        -- Преобразуем уровень сенда в угол (как у панорамы)
        -- Диапазон от -60 dB до +12 dB, но отображаем как панорама
        local level_db = send_level * 72 - 60  -- 0-1 -> -60 до +12 dB
        level_db = math.max(-60, math.min(12, level_db))
        
        -- Нормализуем для углового диапазона (как у панорамы: 180 градусов)
        local level_normalized = (level_db + 60) / 72  -- 0-1
        level_normalized = math.max(0, math.min(1, level_normalized))
        
        -- Вычисляем угол для полного круга (360 градусов)
        local start_angle = math.pi / 2  -- Начинаем с 6 часов (снизу, 90°)
        local current_angle = start_angle + level_normalized * 2 * math.pi  -- Полный круг 360°
        
        -- Цвет индикатора в зависимости от уровня
        local indicator_color = COLOR_ACTIVE
        if level_db >= 0 then
            -- Красный для положительных значений
            indicator_color = 0xFF4444FF
        elseif level_db >= -12 then
            -- Оранжевый для умеренных значений
            indicator_color = 0xFF8844FF
        end
        
        -- Рисуем дуговой слайдер впритык к кругу (как у панорамы)
        local track_radius = radius + 1  -- Слайдер впритык к кругу
        local track_thickness = 2
        local segments = 32
        
        -- Темная дорожка слайдера (полный круг 360°) - впритык
        for i = 0, segments do
            local angle1 = start_angle + (i / segments) * 2 * math.pi
            local angle2 = start_angle + ((i + 1) / segments) * 2 * math.pi
            
            local x1_outer = cx + math.cos(angle1) * (track_radius + track_thickness)
            local y1_outer = cy + math.sin(angle1) * (track_radius + track_thickness)
            local x1_inner = cx + math.cos(angle1) * track_radius
            local y1_inner = cy + math.sin(angle1) * track_radius
            
            local x2_outer = cx + math.cos(angle2) * (track_radius + track_thickness)
            local y2_outer = cy + math.sin(angle2) * (track_radius + track_thickness)
            local x2_inner = cx + math.cos(angle2) * track_radius
            local y2_inner = cy + math.sin(angle2) * track_radius
            
            -- Рисуем сегмент темной дорожки
            reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
                x1_outer, y1_outer, x2_outer, y2_outer, 
                x2_inner, y2_inner, x1_inner, y1_inner, 
                0x404040FF)
        end
        
        -- Активная часть слайдера (от начала до текущей позиции) - полный круг
        local active_segments = math.floor(segments * level_normalized)
        for i = 0, active_segments do
            local progress = math.min(i / segments, level_normalized)
            local angle1 = start_angle + progress * 2 * math.pi
            local angle2 = start_angle + math.min((i + 1) / segments, level_normalized) * 2 * math.pi
            
            local x1_outer = cx + math.cos(angle1) * (track_radius + track_thickness)
            local y1_outer = cy + math.sin(angle1) * (track_radius + track_thickness)
            local x1_inner = cx + math.cos(angle1) * track_radius
            local y1_inner = cy + math.sin(angle1) * track_radius
            
            local x2_outer = cx + math.cos(angle2) * (track_radius + track_thickness)
            local y2_outer = cy + math.sin(angle2) * (track_radius + track_thickness)
            local x2_inner = cx + math.cos(angle2) * track_radius
            local y2_inner = cy + math.sin(angle2) * track_radius
            
            -- Рисуем сегмент активной части
            reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
                x1_outer, y1_outer, x2_outer, y2_outer, 
                x2_inner, y2_inner, x1_inner, y1_inner, 
                indicator_color)
        end
        
        -- НЕ рисуем точку на конце (как у панорамы)
        
        -- Рисуем стилизованную стрелку-шеврон с наклонными основаниями
        local arrow_color = indicator_color  -- Тот же цвет что и линии роутинга
        local arrow_height = radius * 0.5  -- Увеличиваем высоту стрелки
        local arrow_half_base = arrow_height * 0.9  -- Увеличиваем ширину основания
        
        -- Позиция: основание выше канавки слайдера на несколько пикселей
        local arrow_x = cx
        local arrow_top_y = cy - radius - arrow_height - 5  -- Вершина стрелки (поднята на 5 пикселей)
        local arrow_base_y = cy - radius - 5  -- Основание выше канавки слайдера
        
        -- Создаем четкий симметричный шеврон из двух треугольников
        -- Левая часть шеврона
        local left_outer_x = arrow_x - arrow_half_base
        local left_inner_x = arrow_x - arrow_half_base * 0.2  -- Внутренний край левой части
        local left_bottom_y = arrow_base_y
        local left_top_y = arrow_base_y - arrow_height * 0.3  -- Скошенный верх левой части
        
        -- Правая часть шеврона  
        local right_outer_x = arrow_x + arrow_half_base
        local right_inner_x = arrow_x + arrow_half_base * 0.2  -- Внутренний край правой части
        local right_bottom_y = arrow_base_y
        local right_top_y = arrow_base_y - arrow_height * 0.3  -- Скошенный верх правой части
        
        -- Рисуем левую часть шеврона (треугольник)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
            left_outer_x, left_bottom_y,    -- Левый нижний угол
            left_inner_x, left_top_y,       -- Внутренний скошенный угол
            arrow_x, arrow_top_y,           -- Вершина стрелки
            arrow_color)
        
        -- Рисуем правую часть шеврона (треугольник)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
            right_outer_x, right_bottom_y,  -- Правый нижний угол
            right_inner_x, right_top_y,     -- Внутренний скошенный угол
            arrow_x, arrow_top_y,           -- Вершина стрелки
            arrow_color)
        
        -- Отображаем значение dB в центре круга только при взаимодействии
        if show_db then
            reaper.ImGui_PushFont(ctx, font_tiny)
            local send_text = string.format("%.1f", level_db)
            local text_size_x, text_size_y = reaper.ImGui_CalcTextSize(ctx, send_text)
            local text_x = cx - text_size_x / 2
            local text_y = cy - text_size_y / 2
            
            -- Сохраняем текущую позицию курсора
            local cursor_x, cursor_y = reaper.ImGui_GetCursorPos(ctx)
            
            -- Устанавливаем позицию для текста
            reaper.ImGui_SetCursorScreenPos(ctx, text_x, text_y)
            reaper.ImGui_TextColored(ctx, COLOR_TEXT, send_text)
            
            -- Восстанавливаем позицию курсора
            reaper.ImGui_SetCursorPos(ctx, cursor_x, cursor_y)
            reaper.ImGui_PopFont(ctx)
        end
        
        return {
            ring_area = {x = cx - radius, y = cy - radius, w = radius * 2, h = radius * 2},
            triangle_area = {x = arrow_x - arrow_half_base, y = arrow_top_y, w = arrow_half_base * 2, h = arrow_height}
        }
    else
        -- Обычный треугольник для неназначенных сендов
        
    if is_triangle_hovered then
        local box_padding = 4
        local tri_size = ICON_SIZE * 0.75
        local rect_x1 = cx - tri_size / 2 - box_padding
        local rect_y1 = cy - 2 - tri_size * 0.4 - box_padding
        local rect_x2 = cx + tri_size / 2 + box_padding
        local rect_y2 = cy - 2 + tri_size * 0.4 + box_padding
        local corner_radius = 5
        reaper.ImGui_DrawList_AddRect(
            draw_list, rect_x1, rect_y1, rect_x2, rect_y2,
            COLOR_ACTIVE, corner_radius, 0, 2
        )
    end

    draw_triangle_up(draw_list, cx, cy - 2, ICON_SIZE * 0.75, COLOR_TRIANGLE)  -- Используем исходный размер ICON_SIZE
        return nil
    end
end

local function fl_vslider(ctx, label, width, height, value, min_val, max_val, track_index, pressure_offset)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local pos_x, pos_y = reaper.ImGui_GetCursorScreenPos(ctx)
    
    -- Применяем смещение от давления частиц (ограничиваем максимальное смещение)
    pressure_offset = pressure_offset or 0
    local max_offset = 6
    pressure_offset = math.min(pressure_offset * 0.01, max_offset)
    
    -- Вычисляем нормализованное значение
    local normalized = (value - min_val) / (max_val - min_val)
    normalized = math.max(0, math.min(1, normalized))
    
    -- Получаем цвет трека для фона слайдера
    local track_color = get_enhanced_track_color(track_index or 0)
    local darker_track_color = adjust_color_brightness(track_color, -0.3)
    
    -- Рисуем узкую линию слайдера (центр) с цветом трека
    local track_width = 3
    local track_x = pos_x + (width - track_width) / 2
    reaper.ImGui_DrawList_AddRectFilled(draw_list, track_x, pos_y, track_x + track_width, pos_y + height, darker_track_color, 0)
    reaper.ImGui_DrawList_AddRect(draw_list, track_x, pos_y, track_x + track_width, pos_y + height, track_color, 0, 0, 1)
    
    -- Рисуем шкалы дБ с обеих сторон
    local scale_marks = {12, 6, 0, -6, -12, -18, -24, -30, -40, -50}
    for _, db_val in ipairs(scale_marks) do
        if db_val >= min_val and db_val <= max_val then
            local mark_normalized = (db_val - min_val) / (max_val - min_val)
            local mark_y = pos_y + (1 - mark_normalized) * height
            
            if db_val == 0 then
                -- 0dB - более заметная отметка с обеих сторон
                reaper.ImGui_DrawList_AddLine(draw_list, track_x - 4, mark_y, track_x, mark_y, 0x808080FF, 1)
                reaper.ImGui_DrawList_AddLine(draw_list, track_x + track_width, mark_y, track_x + track_width + 4, mark_y, 0x808080FF, 1)
            elseif db_val % 12 == 0 then
                -- Основные отметки (каждые 12dB) с обеих сторон
                reaper.ImGui_DrawList_AddLine(draw_list, track_x - 3, mark_y, track_x, mark_y, 0x606060FF, 1)
                reaper.ImGui_DrawList_AddLine(draw_list, track_x + track_width, mark_y, track_x + track_width + 3, mark_y, 0x606060FF, 1)
            else
                -- Промежуточные отметки с обеих сторон
                reaper.ImGui_DrawList_AddLine(draw_list, track_x - 2, mark_y, track_x, mark_y, 0x404040FF, 1)
                reaper.ImGui_DrawList_AddLine(draw_list, track_x + track_width, mark_y, track_x + track_width + 2, mark_y, 0x404040FF, 1)
            end
        end
    end
    
    -- Вычисляем позицию ползунка (маленький прямоугольник) с учетом смещения от частиц
    local handle_height = 4
    local handle_width = width - 4
    local handle_y = pos_y + (1 - normalized) * (height - handle_height) - pressure_offset
    local handle_x = pos_x + 2
    
    -- Рисуем ползунок (светло-серый) с эффектом тряски от частиц
    local shake_intensity = pressure_offset * 0.3
    local shake_x = handle_x + (math.random() - 0.5) * shake_intensity
    local shake_y = handle_y + (math.random() - 0.5) * shake_intensity
    
    -- Основной ползунок
    reaper.ImGui_DrawList_AddRectFilled(draw_list, shake_x, shake_y, shake_x + handle_width, shake_y + handle_height, 0xC0C0C0FF, 0)
    
    -- Дополнительный эффект свечения при высоком давлении
    if pressure_offset > 2 then
        local glow_alpha = math.min(pressure_offset / 6, 1) * 0.3
        local glow_color = (0xFF << 24) | (math.floor(255 * glow_alpha) << 16) | (math.floor(255 * glow_alpha) << 8) | math.floor(255 * glow_alpha)
        reaper.ImGui_DrawList_AddRectFilled(draw_list, handle_x - 1, handle_y - 1, handle_x + handle_width + 1, handle_y + handle_height + 1, glow_color, 0)
    end
    
    -- Создаем невидимую кнопку для взаимодействия
    reaper.ImGui_InvisibleButton(ctx, label, width, height)
    local is_active = reaper.ImGui_IsItemActive(ctx)
    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    
    -- Обработка взаимодействия с мышью
    local new_value = value
    if is_active then
        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
        local relative_y = mouse_y - pos_y
        local new_normalized = 1 - (relative_y / height)
        new_normalized = math.max(0, math.min(1, new_normalized))
        new_value = min_val + new_normalized * (max_val - min_val)
    end
    
    -- Обработка колеса мыши
    if is_hovered and wheel ~= 0 then
        local step = (max_val - min_val) * 0.02
        new_value = value + wheel * step
        new_value = math.max(min_val, math.min(max_val, new_value))
    end
    
    -- Возвращаем также позицию ползунка для взаимодействия с частицами
    return new_value ~= value, new_value, handle_y
end

local function draw_circle_arrow(draw_list, cx, cy, size, color)
    local r = size/2 - 2
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, r, 0x1A1A1AFF, 24)
    reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, r, color, 32, 2)
    draw_triangle_up(draw_list, cx, cy - r + 6, size * 0.3, color)
end

local function draw_circle_arrow_big(draw_list, cx, cy, size, color)
    local r = size/2 - 2
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, r, 0x1A1A1AFF, 24)
    reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, r, color, 32, 3)
    draw_triangle_up(draw_list, cx, cy - r + 7, size * 0.4, color)
end

local function remove_all_sends_from_track(track)
    for i = reaper.GetTrackNumSends(track, 0)-1, 0, -1 do
        reaper.RemoveTrackSend(track, 0, i)
    end
end

local function create_sidechain_send(from_track, dest_track, exclusive)
    if exclusive then 
        remove_all_sends_from_track(from_track)
        reaper.SetMediaTrackInfo_Value(from_track, 'B_MAINSEND', 0)
    end
    local send_idx = reaper.CreateTrackSend(from_track, dest_track)
    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "I_SENDCHAN", 2)
    
    -- Устанавливаем уровень по умолчанию (0 dB)
    local level_db = 0  -- 0 dB
    local volume_value = 10 ^ (level_db / 20)
    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
end

local function create_normal_send(from_track, dest_track, exclusive)
    if exclusive then 
        remove_all_sends_from_track(from_track)
        reaper.SetMediaTrackInfo_Value(from_track, 'B_MAINSEND', 0)
    end
    local send_idx = reaper.CreateTrackSend(from_track, dest_track)
    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "I_SENDCHAN", 0)
    
    -- Устанавливаем уровень по умолчанию (0 dB)
    local level_db = 0  -- 0 dB
    local volume_value = 10 ^ (level_db / 20)
    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
end

local function enable_master_send(track)
    reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 1)
end

local function disable_master_send(track)
    reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
end

local function create_master_send_exclusive(track)
    remove_all_sends_from_track(track)
    enable_master_send(track)
end

local function create_sidechain_to_master(track, exclusive)
    if exclusive then
        remove_all_sends_from_track(track)
        disable_master_send(track)
    end
    local master_track = reaper.GetMasterTrack(0)
    local send_idx = reaper.CreateTrackSend(track, master_track)
    reaper.SetTrackSendInfo_Value(track, 0, send_idx, "I_SRCCHAN", 2)
end

local function loop()
    if not ctx then 
        SetupContext()
        if not ctx then return end
    end
    
    -- Глобальная проверка для завершения перетаскивания сендов
    if send_mouse_dragging and not reaper.ImGui_IsMouseDown(ctx, 0) then
        send_mouse_dragging = false
        send_mouse_dragging_track = nil
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
    end
    
    -- Логика Ctrl + перетаскивание (проверяем до создания окна)
    local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
    local mouse_down = reaper.ImGui_IsMouseDown(ctx, 0)
    local mouse_clicked = reaper.ImGui_IsMouseClicked(ctx, 0)
    local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
    
    -- Начало отслеживания потенциального перетаскивания с Ctrl
    if ctrl_held and mouse_clicked and not ctrl_drag_active then
        ctrl_drag_start_x = mouse_x
        ctrl_drag_start_y = mouse_y
        ctrl_drag_potential = true
    end
    
    -- Активация перетаскивания только при движении мыши
    if ctrl_drag_potential and ctrl_held and mouse_down then
        local drag_distance = math.sqrt((mouse_x - ctrl_drag_start_x)^2 + (mouse_y - ctrl_drag_start_y)^2)
        if drag_distance > 5 then  -- Минимальное расстояние для активации перетаскивания
            ctrl_drag_active = true
            ctrl_drag_potential = false
        end
    end
    
    -- Завершение перетаскивания
    if (ctrl_drag_active or ctrl_drag_potential) and not mouse_down then
        ctrl_drag_active = false
        ctrl_drag_potential = false
    end
    
    -- Логика Shift + колесо мыши для перемещения треков
    local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())
    local mouse_wheel = reaper.ImGui_GetMouseWheel(ctx)
    
    if shift_held and mouse_wheel ~= 0 then
        -- Собираем все выделенные треки (исключая мастер)
        local selected_track_indices = {}
        for i = 1, reaper.CountTracks(0) do  -- Начинаем с 1, чтобы исключить мастер
            if selected_tracks[i] then
                table.insert(selected_track_indices, i)
            end
        end
        
        if #selected_track_indices > 0 then
            local track_count = reaper.CountTracks(0)
            
            -- Определяем направление перемещения
            local move_direction = 0
            if mouse_wheel > 0 then
                move_direction = -1  -- Колесо вверх - перемещаем влево
            elseif mouse_wheel < 0 then
                move_direction = 1   -- Колесо вниз - перемещаем вправо
            end
            
            if move_direction ~= 0 then
                -- Сортируем индексы треков для правильного порядка перемещения
                table.sort(selected_track_indices)
                
                -- Проверяем возможность перемещения группы
                local can_move = true
                local first_track_idx = selected_track_indices[1]
                local last_track_idx = selected_track_indices[#selected_track_indices]
                
                if move_direction == -1 and first_track_idx <= 1 then
                    can_move = false  -- Нельзя двигать влево, если первый трек уже в позиции 1
                elseif move_direction == 1 and last_track_idx >= track_count then
                    can_move = false  -- Нельзя двигать вправо, если последний трек уже в конце
                end
                
                if can_move then
                    -- Выделяем все треки в Reaper для группового перемещения
                    reaper.Main_OnCommand(40297, 0)  -- Снимаем выделение со всех треков
                    
                    for _, track_idx in ipairs(selected_track_indices) do
                        local track = reaper.GetTrack(0, track_idx - 1)  -- -1 потому что API использует 0-based индексы
                        if track then
                            reaper.SetTrackSelected(track, true)
                        end
                    end
                    
                    -- Определяем позицию для вставки
                    local insert_before_pos
                    if move_direction == -1 then
                        -- Перемещение влево
                        insert_before_pos = first_track_idx - 2  -- -1 для 0-based, -1 для сдвига влево
                    else
                        -- Перемещение вправо
                        insert_before_pos = last_track_idx + 1  -- +1 для сдвига вправо, уже 0-based
                    end
                    
                    -- Выполняем групповое перемещение
                    local success = reaper.ReorderSelectedTracks(insert_before_pos, 0)
                    
                    if success then
                        -- Принудительно обновляем проект и интерфейс
                        reaper.UpdateArrange()
                        reaper.TrackList_AdjustWindows(false)
                        reaper.UpdateTimeline()
                        
                        -- Полностью очищаем старое выделение
                        selected_tracks = {}
                        selected_track_index = nil
                        
                        -- Принудительно обновляем информацию о треках
                        update_track_info()
                        
                        -- Актуализируем данные сендов из текущего состояния Reaper
                        init_send_data()
                        
                        -- Обновляем данные посылов после перемещения треков
                        update_send_data_after_track_move()
                        
                        -- Обновляем выделение из Reaper
                        update_selected_from_reaper()
                        
                        -- Вычисляем новые позиции треков для автоскролла
                        local new_positions = {}
                        for i, track_idx in ipairs(selected_track_indices) do
                            local new_pos = track_idx + move_direction
                            table.insert(new_positions, new_pos)
                        end
                        
                        -- Восстанавливаем выделение на новых позициях
                        for _, new_pos in ipairs(new_positions) do
                            local moved_track = reaper.GetTrack(0, new_pos - 1)
                            if moved_track then
                                reaper.SetTrackSelected(moved_track, true)
                                selected_tracks[new_pos] = true
                                if not selected_track_index then
                                    selected_track_index = new_pos  -- Устанавливаем первый как основной
                                end
                            end
                        end
                        
                        -- Автоскролл к первому перемещенному треку
                        if #new_positions > 0 then
                            track_move_autoscroll_target = new_positions[1]
                        end
                    end
                end
            end
        end
    end
    
    -- Определяем флаги окна в зависимости от состояния Ctrl + перетаскивания
    local window_flags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    if ctrl_drag_active then
        window_flags = window_flags | reaper.ImGui_WindowFlags_NoMove()
    end
    
    local visible, open = reaper.ImGui_Begin(ctx, 'FL Mixer Table Select', true, window_flags)
    if visible then
        reaper.ImGui_PushFont(ctx, font)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COLOR_BG)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COLOR_BG)
        
        -- Кнопка для открытия панели настроек частиц
        if reaper.ImGui_Button(ctx, "Particle Settings (P)", 140, 20) then
            show_particle_settings = not show_particle_settings
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Open particle effects settings panel\nHotkey: P")
        end
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_Text(ctx, "FL Mixer Enhanced")
        
        -- Горячая клавиша P для открытия панели настроек частиц
        if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_P()) then
            show_particle_settings = not show_particle_settings
        end
        
        update_selected_from_reaper()
        update_track_info()
        
        -- Обновляем виртуальное маппирование FX для выбранного трека
        if selected_track then
            update_virtual_mapping(selected_track)
            
            -- Проверяем, добавился ли новый FX и есть ли целевой слот
            if target_slot_for_new_fx and target_track_for_new_fx then
                local new_fx_count = reaper.TrackFX_GetCount(target_track_for_new_fx)
                local old_fx_count = new_fx_count - 1  -- Предполагаем, что добавился один FX
                
                if new_fx_count > old_fx_count then
                    -- Новый FX добавлен, помещаем его в целевой слот
                    local mapping = get_virtual_mapping(target_track_for_new_fx)
                    local new_fx_idx = new_fx_count - 1  -- Последний добавленный FX
                    
                    -- Освобождаем целевой слот если он занят
                    if mapping[target_slot_for_new_fx] then
                        -- Находим первый свободный слот для перемещения существующего FX
                        for slot = 1, 10 do
                            if not mapping[slot] then
                                mapping[slot] = mapping[target_slot_for_new_fx]
                                break
                            end
                        end
                    end
                    
                    -- Помещаем новый FX в целевой слот
                    mapping[target_slot_for_new_fx] = new_fx_idx
                    SyncFXChainFromSlots(target_track_for_new_fx)
                    
                    -- Сбрасываем целевой слот и трек
                    target_slot_for_new_fx = nil
                    target_track_for_new_fx = nil
                end
            end
            
        end
        
        -- Обновляем количество треков в каждом кадре для актуальности
        local track_count = reaper.CountTracks(0)
        local total_tracks = track_count + 1
        
        local win_width, win_height = reaper.ImGui_GetWindowSize(ctx)
        local available_height = win_height - 10
        
        -- Используем фиксированную высоту треков для предотвращения вертикального скролла
        local channel_height = MIN_CHANNEL_HEIGHT
        local master_height = MIN_MASTER_HEIGHT
        
        -- FX панель
        local fx_panel_width = 240
        local mixer_width = win_width - fx_panel_width
        
        local total_width = MASTER_WIDTH + CHANNEL_WIDTH * track_count
        local need_scroll = total_width > (mixer_width - 20)
        
        -- Устанавливаем нулевые отступы между элементами для заполнения всего пространства
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
        
        -- Рассчитываем ширину доступного пространства и ширину всех треков
        local available_width = mixer_width - 20
        local tracks_width = total_width
        
        -- Если треков мало, распределяем их равномерно по ширине окна
        local track_spacing = 0
        if not need_scroll and track_count > 0 then
            -- Рассчитываем равномерное расстояние между треками
            track_spacing = math.floor((available_width - tracks_width) / track_count)
            -- Ограничиваем максимальное расстояние
            track_spacing = math.min(track_spacing, 10) -- Максимальный отступ 10 пикселей
        end
        
        local child_window_open = false
        if need_scroll then
            -- Используем автоматическую высоту (0) и включаем только горизонтальную прокрутку
            local flags = reaper.ImGui_WindowFlags_HorizontalScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
            child_window_open = reaper.ImGui_BeginChild(ctx, 'ScrollRegion', available_width, 0, reaper.ImGui_ChildFlags_None(), flags)
        end
        local icon_centers = {}
        local track_positions = {}  -- Таблица для хранения позиций треков
        
        -- Всегда создаем невидимый элемент для установки ширины контента
        -- Это необходимо для правильной работы горизонтальной прокрутки
        if child_window_open then
            -- Создаем невидимый элемент с полной шириной всех треков
            reaper.ImGui_Dummy(ctx, tracks_width, 1)
            -- Возвращаем курсор в начало для размещения треков
            reaper.ImGui_SetCursorPos(ctx, 0, 0)
        end
        
        -- Обновляем стиль отступов между элементами, если нужно распределить треки
        if not need_scroll and track_spacing > 0 then
            reaper.ImGui_PopStyleVar(ctx, 1) -- Удаляем предыдущий стиль
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), track_spacing, 0)
        end
        
        -- Очищаем неиспользуемые системы частиц
        cleanup_pixel_systems(track_count)
        
        for i = 0, track_count do
            local send_icon_clicked = false  -- Переменная для отслеживания кликов по иконке сенда
            local triangle_clicked = false  -- Переменная для отслеживания кликов по треугольнику
            local fx_button_clicked = false  -- Переменная для отслеживания кликов по FX кнопке
            local pan_right_clicked = false
            local stereo_right_clicked = false
            local volume_right_clicked = false
            local is_master = (i == 0)
            local track = is_master and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i-1)
            
            -- Проверяем, что трек существует (важно после удаления треков)
            if not track then
                break  -- Выходим из цикла если трек не существует
            end
            
            local base_name = track_names[i] or (is_master and "MASTER" or ("Track " .. i))
            local is_selected = selected_tracks[i] or false
            local width = is_master and MASTER_WIDTH or CHANNEL_WIDTH
            local height = is_master and master_height or channel_height

            -- Используем явное позиционирование только когда нужна прокрутка
            if need_scroll and child_window_open then
                -- Явно устанавливаем позицию каждого трека
                local x_pos = 0
                for j = 0, i-1 do
                    local j_width = (j == 0) and MASTER_WIDTH or CHANNEL_WIDTH
                    x_pos = x_pos + j_width + 1  -- +1 для spacing
                end
                reaper.ImGui_SetCursorPos(ctx, x_pos, 0)
            end

            -- Основной child-канал
            local track_child_open = reaper.ImGui_BeginChild(ctx, '##bg'..i, width, height, 0, reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse())
            
            -- Сохраняем позицию трека для логики перетаскивания
            if track_child_open then
                local track_x, track_y = reaper.ImGui_GetWindowPos(ctx)
                track_positions[i] = {
                    x = track_x,
                    y = track_y,
                    width = width,
                    height = height
                }
                
                -- Проверяем, находится ли мышь над этим треком во время Ctrl + перетаскивание
                if ctrl_drag_active and ctrl_held and mouse_down and not is_master then  -- Исключаем мастер-трек
                    -- Проверяем, что мышь действительно перемещается (перетягивание)
                    local drag_distance = math.sqrt((mouse_x - ctrl_drag_start_x)^2 + (mouse_y - ctrl_drag_start_y)^2)
                    if drag_distance > 5 then  -- Минимальное расстояние для считывания как перетягивание
                        local track_under_mouse = get_track_under_mouse(mouse_x, mouse_y, track_positions)
                        if track_under_mouse == i then
                            -- Выделяем трек при перетягивании
                            if not selected_tracks[i] then
                                set_selected_track(i, true)  -- true = ctrl_held
                            end
                        end
                    end
                end
            end
            
            -- ПОДСВЕТКА внутри child (градиентный фон с цветами Reaper)
            do
                local child_min_x, child_min_y = reaper.ImGui_GetWindowPos(ctx)
                draw_gradient_track_background(ctx, child_min_x, child_min_y, width, height, i, is_selected)
                reaper.ImGui_DrawList_AddRect(reaper.ImGui_GetWindowDrawList(ctx), child_min_x, child_min_y, child_min_x + width, child_min_y + height, 0x404040FF, 0, 0, 1)
            end

            -- ЦВЕТНАЯ ПОЛОСА ТРЕКА (временно отключена)
            --[[
            do
                local child_min_x, child_min_y = reaper.ImGui_GetWindowPos(ctx)
                draw_track_color_strip(ctx, child_min_x, child_min_y, width, height, i)
            end
            --]]

            -- Невидимая зона для верхней части трека (номер и название)
            local header_height = 28  -- Уменьшено с 45 до 28, чтобы не перекрывать лампочку на Y=29
            reaper.ImGui_PushID(ctx, "header"..i)
            reaper.ImGui_SetCursorPos(ctx, 0, 0)
            reaper.ImGui_InvisibleButton(ctx, "track_header", width, header_height)
            
            -- Обработка левого клика для выделения трека
            if reaper.ImGui_IsItemClicked(ctx, 0) and not ctrl_drag_active then
                local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
                set_selected_track(i, ctrl_held)
            end
            
            -- Обработка правого клика для контекстного меню
            if reaper.ImGui_IsItemClicked(ctx, 1) and not ctrl_drag_active then
                set_selected_track(i, false)
            end
            if reaper.ImGui_BeginPopupContextItem(ctx, "track_ctx_"..i) then
                local track = (i == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i-1)
                draw_track_context_menu(i, track)
                reaper.ImGui_EndPopup(ctx)
            end
            reaper.ImGui_PopID(ctx)
            reaper.ImGui_SetCursorPos(ctx, 0, 0)

            -- Отображение нумерации над названием (только для обычных треков)
            if not is_master then
                reaper.ImGui_PushFont(ctx, font_small)  -- Используем более крупный шрифт
                local track_number = tostring(i)
                local number_w, number_h = reaper.ImGui_CalcTextSize(ctx, track_number)
                local number_center_x = (width - number_w) / 2
                
                if is_selected then
                    -- Для выделенных треков: яркая белая рамка вокруг цифры (тоньше в 2 раза)
                    local dl = reaper.ImGui_GetWindowDrawList(ctx)
                    local window_x, window_y = reaper.ImGui_GetWindowPos(ctx)
                    
                    local number_x = window_x + math.max(2, number_center_x)
                    local number_y = window_y + 2
                    local padding = 2
                    
                    -- Яркая белая рамка вокруг цифры (толщина 1 вместо 2)
                    reaper.ImGui_DrawList_AddRect(dl, 
                        number_x - padding, number_y - 1, 
                        number_x + number_w + padding, number_y + number_h + 1, 
                        0xFFFFFFFF, 0, 0, 1)
                    
                    -- Яркая белая цифра (того же цвета что и рамка)
                    reaper.ImGui_SetCursorPos(ctx, math.max(2, number_center_x), 2)
                    reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, track_number)
                else
                    -- Для невыделенных треков: еще более яркие цифры
                    reaper.ImGui_SetCursorPos(ctx, math.max(2, number_center_x), 2)
                    reaper.ImGui_TextColored(ctx, 0xF0F0F0FF, track_number)  -- Еще более яркий серый
                end
                
                reaper.ImGui_PopFont(ctx)
            end

            -- Отображение названия трека
            reaper.ImGui_PushFont(ctx, font_small)
            local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, base_name)
            local center_x = (width - text_w) / 2
            local name_y = is_master and 8 or 15  -- Для мастера - как раньше, для треков - ниже номера
            reaper.ImGui_SetCursorPos(ctx, math.max(2, center_x), name_y)
            reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, base_name)
            reaper.ImGui_PopFont(ctx)
            reaper.ImGui_Dummy(ctx, 0, 6)
            -- =========== ЛАМПА mute/solo ===========
            if not is_master and track then
                local mute = reaper.GetMediaTrackInfo_Value(track, 'B_MUTE') == 1
                local solo = reaper.GetMediaTrackInfo_Value(track, 'I_SOLO') ~= 0
                
                -- Сохраняем оригинальный SetCursorPos для layout
                reaper.ImGui_SetCursorPos(ctx, (width-13)/2, 29)
                
                -- Рисуем невидимую кнопку для сохранения layout
                reaper.ImGui_InvisibleButton(ctx, 'lamp_layout'..i, 13, 18)
                
                -- Рисуем лампочку в абсолютных координатах (на 29 пикселей от верха трека)
                local window_x, window_y = reaper.ImGui_GetWindowPos(ctx)
                local lamp_x = window_x + (width - 13) / 2
                local lamp_y = window_y + 29  -- Позиция на 29 пикселей от верха трека
                
                local l, r = simple_lamp_button_absolute(ctx, 'lamp'..i, not mute, lamp_x, lamp_y, 13)
                if l then
                    reaper.SetMediaTrackInfo_Value(track, 'B_MUTE', mute and 0 or 1)
                    reaper.SetMediaTrackInfo_Value(track, 'I_SOLO', 0)
                end
                if r then
                    if solo then
                        solo_off()
                    else
                        solo_on(i)
                    end
                end
            else
                reaper.ImGui_Dummy(ctx, 0, 18)
            end
            -- =========== /ЛАМПА ===========
            
            -- =========== ПАНОРАМА под кнопками мют/соло (абсолютное позиционирование) ===========
            reaper.ImGui_Dummy(ctx, 0, 5)
            local pan = reaper.GetMediaTrackInfo_Value(track, 'D_PAN')
            
            -- Сохраняем текущую позицию курсора для панорамы
            local saved_pan_cursor_x, saved_pan_cursor_y = reaper.ImGui_GetCursorPos(ctx)
            
            -- Вычисляем абсолютную позицию для крутилки панорамы (по центру трека, опущено на 29 пикселей)
            local window_x, window_y = reaper.ImGui_GetWindowPos(ctx)
            local pan_pos_x = window_x + (width - KNOB_SIZE) / 2
            local pan_pos_y = window_y + saved_pan_cursor_y + 12  -- Поднято на 40 пикселей вверх (было 52, стало 12)
            
            local pan_changed, new_pan, pan_rc = simple_knob_pan_absolute(ctx, 'Pan##'..i, pan, -1, 1, KNOB_SIZE, COLOR_ACTIVE, pan_pos_x, pan_pos_y)

            -- Контекстное меню при правом клике на панораму
            if pan_rc then
                pan_right_clicked = true
                reaper.ImGui_OpenPopup(ctx, "PanMenu_"..i)
            end
            
            -- Отображение контекстного меню панорамы
            if reaper.ImGui_BeginPopup(ctx, "PanMenu_"..i) then
                if reaper.ImGui_Selectable(ctx, "Reset") then
                    reaper.SetMediaTrackInfo_Value(track, 'D_PAN', 0.0)  -- Центр
                end
                
                if reaper.ImGui_Selectable(ctx, "Copy Value") then
                    copied_pan = pan
                end
                
                -- Paste Value - активно только если есть скопированное значение
                if copied_pan then
                    if reaper.ImGui_Selectable(ctx, "Paste Value") then
                        reaper.SetMediaTrackInfo_Value(track, 'D_PAN', copied_pan)
                    end
                else
                    -- Неактивный пункт меню
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                    reaper.ImGui_Selectable(ctx, "Paste Value", false, reaper.ImGui_SelectableFlags_Disabled())
                    reaper.ImGui_PopStyleColor(ctx, 1)
                end
                
                reaper.ImGui_EndPopup(ctx)
            end
            
            if pan ~= new_pan then
                reaper.SetMediaTrackInfo_Value(track, 'D_PAN', new_pan)
                -- Выделяем трек только при изменении мышкой (не колесом) и не во время Ctrl + перетаскивание
                if pan_changed and not ctrl_drag_active then
                    local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
                    set_selected_track(i, ctrl_held)
                end
            end
            
            -- Восстанавливаем позицию курсора после панорамы
            reaper.ImGui_SetCursorPos(ctx, saved_pan_cursor_x, saved_pan_cursor_y)
            -- =========== /ПАНОРАМА ===========
            
            -- =========== СТЕРЕО РАЗДЕЛЕНИЕ (абсолютное позиционирование) ===========
            -- Инициализируем значение стерео разделения для трека если нужно
            if not stereo_separation[i] then
                stereo_separation[i] = 0.5  -- Значение по умолчанию (50%)
            end
            
            -- Сохраняем текущую позицию курсора
            local saved_cursor_x, saved_cursor_y = reaper.ImGui_GetCursorPos(ctx)
            
            -- Вычисляем абсолютную позицию для крутилки (слева от панорамы)
            local window_x, window_y = reaper.ImGui_GetWindowPos(ctx)
            local stereo_sep_x = window_x + 1.5  -- Перемещено на 1,5 пикселя вправо (было 0, стало 1.5)
            local stereo_sep_y = window_y + saved_cursor_y + 49  -- Поднято на 40 пикселей вверх (было 89, стало 49)
            
            local stereo_sep_value = stereo_separation[i]
            
            -- Определяем, нужно ли показывать текст
            local current_time = reaper.time_precise()
            local show_text = false
            
            -- Проверяем, есть ли активный таймер для этого трека
            if stereo_text_show_timer[i] and (current_time - stereo_text_show_timer[i]) < stereo_text_show_duration then
                show_text = true
            end
            
            -- Проверяем левый клик мыши в области крутилки
            local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
            local dx = mouse_x - stereo_sep_x - SMALL_KNOB_SIZE/2
            local dy = mouse_y - stereo_sep_y - SMALL_KNOB_SIZE/2
            local distance = math.sqrt(dx*dx + dy*dy)
            
            if distance <= SMALL_KNOB_SIZE/2 and reaper.ImGui_IsMouseClicked(ctx, 0) then
                show_text = true
                stereo_text_show_timer[i] = current_time
            end
            
            local stereo_changed, new_stereo_sep, stereo_rc = small_stereo_separation_knob(ctx, stereo_sep_x, stereo_sep_y, SMALL_KNOB_SIZE, stereo_sep_value, 0, 1, i, show_text)

            -- Обработка правого клика для контекстного меню
            if stereo_rc then
                stereo_right_clicked = true
                reaper.ImGui_OpenPopup(ctx, "stereo_context_" .. i)
            end
            
            if stereo_changed then
                stereo_separation[i] = new_stereo_sep
                -- Запускаем таймер показа текста при изменении значения
                stereo_text_show_timer[i] = current_time
                -- Здесь можно добавить применение стерео разделения к треку
                -- Например, через плагин или параметр трека
            end
            
            -- Контекстное меню для стереоразделения
            if reaper.ImGui_BeginPopup(ctx, "stereo_context_" .. i) then
                if reaper.ImGui_Selectable(ctx, "Reset") then
                    stereo_separation[i] = 0.5  -- Сброс к 50% (центр)
                end
                
                if reaper.ImGui_Selectable(ctx, "Copy Value") then
                    copied_stereo = stereo_separation[i]
                end
                
                -- Paste Value - активно только если есть скопированное значение
                if copied_stereo then
                    if reaper.ImGui_Selectable(ctx, "Paste Value") then
                        stereo_separation[i] = copied_stereo
                    end
                else
                    -- Неактивный пункт меню
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                    reaper.ImGui_Selectable(ctx, "Paste Value", false, reaper.ImGui_SelectableFlags_Disabled())
                    reaper.ImGui_PopStyleColor(ctx)
                end
                
                reaper.ImGui_EndPopup(ctx)
            end
            
            -- Восстанавливаем позицию курсора
            reaper.ImGui_SetCursorPos(ctx, saved_cursor_x, saved_cursor_y)
            -- =========== /СТЕРЕО РАЗДЕЛЕНИЕ ===========
            
            -- =========== /ПАНОРАМА ===========
            reaper.ImGui_Dummy(ctx, 0, 77)  -- Опущено на 20 пикселей вниз (было 57, стало 77)
            local vol = reaper.GetMediaTrackInfo_Value(track, 'D_VOL')
            local vol_db = 20 * math.log(vol, 10)
            vol_db = math.max(-60, math.min(12, vol_db))
            local slider_height = height - 210  -- Растянут вниз на 30 пикселей (с 240 до 210), чтобы слайдер был длиннее
            local slider_x = (width - SLIDER_WIDTH) / 2 + 8  -- Смещен на 8 пикселей вправо
            
            -- =========== СПЕКТРАЛЬНЫЙ МЕТР (слева от слайдера) ===========
            local spectrum_meter_x = slider_x - PIXEL_CONFIG.meter_width - 8  -- 8 пикселей отступа от слайдера
            local spectrum_meter_y = reaper.ImGui_GetCursorPosY(ctx)
            
            -- Получаем уровень трека для частиц
            local level = get_track_audio_level(i) or 0
            
            -- Вычисляем базовые координаты метра
            local base_meter_x = window_x + spectrum_meter_x
            local base_meter_y = window_y + spectrum_meter_y
            local meter_width = PIXEL_CONFIG.meter_width
            local meter_height = slider_height
            
            -- 1. Сначала отрисовываем спектральный метр
            draw_spectrum_meter(ctx, base_meter_x, base_meter_y, i, meter_height)
            
            -- 2. Получаем точные координаты метра ПОСЛЕ его отрисовки
            local meter_min_x = base_meter_x
            local meter_min_y = base_meter_y  
            local meter_max_x = base_meter_x + meter_width
            local meter_max_y = base_meter_y + meter_height
            
            -- 3. Затем обновляем и отрисовываем пиксели с точными координатами
            -- используем функцию UpdateFXParticlesFL, которая порождает новые частицы для dB‑метра
            -- Используем сохраненную позицию слайдера из предыдущего кадра
            local saved_handle_y = handle_positions[i] or (meter_min_y + meter_height * 0.8) -- fallback позиция
            local pressure = UpdateFXParticlesFL(i, level, 
                meter_min_x, 
                meter_min_y,
                meter_width, 
                meter_height,
                saved_handle_y)
            
            -- Отрисовываем пиксельную систему ПОСЛЕ метра, чтобы она была поверх
            DrawPixelSystem(i, reaper.ImGui_GetWindowDrawList(ctx), 
                meter_min_x, 
                meter_min_y, 
                meter_width, 
                meter_height)
            -- =========== /СПЕКТРАЛЬНЫЙ МЕТР ===========
            
            reaper.ImGui_SetCursorPosX(ctx, slider_x)
            
            local rv, new_vol_db, handle_y = fl_vslider(ctx, 'Vol##'..i, SLIDER_WIDTH, slider_height, vol_db, -60, 12, i, pressure)
            -- Сохраняем позицию слайдера для использования в UpdateFXParticlesFL
            handle_positions[i] = handle_y

            -- Контекстное меню при правом клике на слайдер
            if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
                volume_right_clicked = true
                reaper.ImGui_OpenPopup(ctx, "VolumeMenu_"..i)
            end
            
            -- Отображение контекстного меню
            if reaper.ImGui_BeginPopup(ctx, "VolumeMenu_"..i) then
                if reaper.ImGui_Selectable(ctx, "Reset") then
                    local new_vol = 10 ^ (0.0 / 20)  -- 0dB = 1.0
                    reaper.SetMediaTrackInfo_Value(track, 'D_VOL', new_vol)
                end
                
                if reaper.ImGui_Selectable(ctx, "Copy Value") then
                    copied_value_db = vol_db  -- Сохраняем в dB
                end
                
                -- Paste Value - активно только если есть скопированное значение
                if copied_value_db then
                    if reaper.ImGui_Selectable(ctx, "Paste Value") then
                        local new_vol = 10 ^ (copied_value_db / 20)
                        reaper.SetMediaTrackInfo_Value(track, 'D_VOL', new_vol)
                    end
                else
                    -- Неактивный пункт меню
                    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                    reaper.ImGui_Selectable(ctx, "Paste Value", false, reaper.ImGui_SelectableFlags_Disabled())
                    reaper.ImGui_PopStyleColor(ctx, 1) -- Явно указываем количество
                end
                
                reaper.ImGui_EndPopup(ctx)
            end
            
            -- Обычное изменение громкости слайдером
            if rv then
                local new_vol = 10 ^ (new_vol_db / 20)
                reaper.SetMediaTrackInfo_Value(track, 'D_VOL', new_vol)
            end
            reaper.ImGui_PushFont(ctx, font_small)
            local vol_text = string.format("%.1f", vol_db)
            local vol_text_w = reaper.ImGui_CalcTextSize(ctx, vol_text)
            -- Позиционируем текст точно по центру снизу от слайдера
            local text_x = slider_x + (SLIDER_WIDTH - vol_text_w) / 2  -- Центрируем текст относительно слайдера
            local current_x, current_y = reaper.ImGui_GetCursorPos(ctx)
            reaper.ImGui_SetCursorPos(ctx, text_x, current_y - 1)  -- Опущено еще на 2 пикселя ниже (было -3, стало -1)
            reaper.ImGui_TextColored(ctx, COLOR_TEXT, vol_text)
            reaper.ImGui_PopFont(ctx)

            -- =========== FX TOGGLE КНОПКА (абсолютное позиционирование справа от слайдера) ===========
            -- Сохраняем текущую позицию курсора
            local saved_fx_cursor_x, saved_fx_cursor_y = reaper.ImGui_GetCursorPos(ctx)
            
            -- Вычисляем абсолютную позицию для FX кнопки (справа от слайдера, зеркально от стерео разделения)
            local fx_button_size = 14  -- Уменьшенный размер кнопки
            local fx_button_offset = is_master and 47 or 27  -- Для мастер трека 47 пикселей (на 20 больше), для остальных 27
            local fx_button_x = window_x + width - fx_button_size - fx_button_offset
            local fx_button_y = window_y + saved_fx_cursor_y - 1 + 12  -- Позиционируем так, чтобы верх кнопки был на уровне низа индикации (current_y - 1 + высота текста)
            
            -- Рисуем FX кнопку
            local fx_button_info = draw_fx_toggle_button(track, i, fx_button_x, fx_button_y, fx_button_size)
            
            -- Обработка кликов и hover для FX кнопки
            if fx_button_info then
                local track_guid = reaper.GetTrackGUID(track)
                local fx_state = get_fx_state(track)
                
                -- Проверяем hover
                local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                local fx_dx = mouse_x - fx_button_x - fx_button_size/2
                local fx_dy = mouse_y - fx_button_y - fx_button_size/2
                local fx_distance = math.sqrt(fx_dx*fx_dx + fx_dy*fx_dy)
                
                if fx_distance <= fx_button_size/2 then
                    fx_button_hover[track_guid] = true
                    
                    -- Обработка клика
                    if reaper.ImGui_IsMouseClicked(ctx, 0) then
                        if fx_state ~= "none" then
                            -- Есть эффекты - переключаем их
                            toggle_track_fx(track)
                            fx_button_clicked = true  -- Устанавливаем флаг клика на FX кнопку
                        elseif is_master then
                            -- Нет эффектов и это мастер трек - выполняем ТОЛЬКО указанный код + принудительное обновление фокуса
                            local master = reaper.GetMasterTrack(0)
                            reaper.SetOnlyTrackSelected(master)
                            reaper.CSurf_OnTrackSelection(master)
                            reaper.TrackList_AdjustWindows(false)  -- Обновляем окна треков
                            reaper.Main_OnCommand(40271, 0)
                            fx_button_clicked = true  -- Устанавливаем флаг клика на FX кнопку
                        end
                    end
                else
                    fx_button_hover[track_guid] = false
                end
            end
            
            -- Восстанавливаем позицию курсора
            reaper.ImGui_SetCursorPos(ctx, saved_fx_cursor_x, saved_fx_cursor_y)
            -- =========== /FX TOGGLE КНОПКА ===========


            -- SEND ICONS (их зона не выделяет трек, только роутит)
            local send_icon_y = height - ICON_SIZE - 11  -- Поднято на 4 пикселя вверх (было 7, стало 11)
            reaper.ImGui_SetCursorPos(ctx, (width - ICON_SIZE) / 2, send_icon_y)
            local send_icon_x, send_icon_y_screen = reaper.ImGui_GetCursorScreenPos(ctx)
            local cx, cy = send_icon_x + ICON_SIZE/2, send_icon_y_screen + ICON_SIZE/2
            icon_centers[i] = {x = cx, y = cy}
            local can_send = (selected_track_index > 0) and (i ~= selected_track_index)
            local is_source = (i == selected_track_index)
            local from_track = (selected_track_index > 0) and reaper.GetTrack(0, selected_track_index-1) or nil
            local dest_track = is_master and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i-1)
            local has_send = (from_track and dest_track) and track_has_send(from_track, dest_track)
            local has_sidechain = (from_track and dest_track) and track_has_sidechain(from_track, dest_track)
            local send_btn_id = 'send_icon_'..i
            if is_master then
                local bigsize = ICON_SIZE + 4
                if selected_track_index > 0 then
                    reaper.ImGui_InvisibleButton(ctx, send_btn_id, bigsize, bigsize)
                    local master_connected = track_routed_to_master(from_track) or has_send
                    local icon_color = master_connected and COLOR_ACTIVE or COLOR_INACTIVE
                    draw_circle_arrow_big(reaper.ImGui_GetWindowDrawList(ctx), cx, cy, bigsize, icon_color)
                    if reaper.ImGui_IsItemClicked(ctx) and not is_source then
                        send_icon_clicked = true
                        if track_routed_to_master(from_track) then
                            disable_master_send(from_track)
                        else
                            enable_master_send(from_track)
                        end
                    end
                    if reaper.ImGui_IsItemClicked(ctx, 1) then
                        send_icon_clicked = true
                        reaper.ImGui_OpenPopup(ctx, "MasterRoutingMenu")
                    end
                    if reaper.ImGui_BeginPopup(ctx, "MasterRoutingMenu") then
                        if reaper.ImGui_Selectable(ctx, "Route to master") then
                            enable_master_send(from_track)
                        end
                        if reaper.ImGui_Selectable(ctx, "Route to master only") then
                            create_master_send_exclusive(from_track)
                        end
                        if reaper.ImGui_Selectable(ctx, "Sidechain to master") then
                            create_sidechain_to_master(from_track, false)
                        end
                        if reaper.ImGui_Selectable(ctx, "Sidechain to master only") then
                            create_sidechain_to_master(from_track, true)
                        end
                        if reaper.ImGui_Selectable(ctx, "Disconnect from master") then
                            disable_master_send(from_track)
                        end
                        reaper.ImGui_EndPopup(ctx)
                    end
                else
                    reaper.ImGui_Dummy(ctx, bigsize, bigsize)
                    draw_circle_arrow_big(reaper.ImGui_GetWindowDrawList(ctx), cx, cy, bigsize, COLOR_INACTIVE)
                end
            else
                if is_source then
                    reaper.ImGui_InvisibleButton(ctx, send_btn_id, ICON_SIZE, ICON_SIZE)
                    local send_icon_hovered = reaper.ImGui_IsItemHovered(ctx)
                    draw_triangle_down(reaper.ImGui_GetWindowDrawList(ctx), cx, cy + 2, ICON_SIZE * 0.9, COLOR_ARROW)
                elseif selected_track_index == 0 then
                    reaper.ImGui_Dummy(ctx, ICON_SIZE, ICON_SIZE)
                    draw_triangle_down(reaper.ImGui_GetWindowDrawList(ctx), cx, cy + 2, ICON_SIZE * 0.9, COLOR_INACTIVE)
                else
                    -- Инициализируем таблицы для сендов если нужно
                    if not send_levels[selected_track_index] then
                        send_levels[selected_track_index] = {}
                    end
                    if not send_states[selected_track_index] then
                        send_states[selected_track_index] = {}
                    end
                    
                    -- Получаем текущий уровень сенда
                    local current_level = send_levels[selected_track_index][i] or DEFAULT_SEND_LEVEL
                    local has_send_state = send_states[selected_track_index][i] or false
                    
                    -- Проверяем реальное состояние сенда в Reaper
                    local real_has_send = has_send or has_sidechain
                    if real_has_send and not has_send_state then
                        -- Сенд был создан извне, синхронизируем состояние
                        send_states[selected_track_index][i] = true
                        -- Получаем реальный уровень сенда только если пользователь не изменяет его
                        local is_user_dragging = send_mouse_dragging and send_mouse_dragging_track == i
                        if not is_user_dragging then
                            local send_idx = track_has_send(from_track, dest_track)
                            if send_idx then
                                local volume = reaper.GetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL")
                                -- Конвертируем линейное значение в нормализованный уровень (0-1)
                                local level_db = 20 * math.log(volume, 10)
                                local normalized_level = (level_db + 60) / 72
                                normalized_level = math.max(0, math.min(1, normalized_level))
                                send_levels[selected_track_index][i] = normalized_level
                                update_guid_tables_for_send(selected_track_index, i, normalized_level, true)
                            else
                                -- Если не удалось получить уровень, устанавливаем по умолчанию
                                send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL
                                update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                            end
                        else
                            -- Пользователь перетаскивает, просто обновляем состояние
                            update_guid_tables_for_send(selected_track_index, i, nil, true)
                        end
                    elseif not real_has_send and has_send_state then
                        -- Сенд был удален извне, синхронизируем состояние
                        send_states[selected_track_index][i] = false
                        update_guid_tables_for_send(selected_track_index, i, nil, false)
                    end
                    
                    -- Создаем увеличенную невидимую кнопку, которая покрывает и круг, и треугольник
                    local button_size = KNOB_SIZE + 20  -- Увеличиваем размер чтобы покрыть треугольник
                    -- Корректируем позицию курсора для центрирования увеличенной кнопки
                    local button_offset = (button_size - ICON_SIZE) / 2
                    reaper.ImGui_SetCursorPos(ctx, (width - button_size) / 2, send_icon_y - button_offset)
                    reaper.ImGui_InvisibleButton(ctx, send_btn_id, button_size, button_size)
                    
                    -- Проверяем общее hover состояние для всего элемента
                    local is_hovered = reaper.ImGui_IsItemHovered(ctx)
                    
                    -- Проверяем hover состояние для треугольника (шеврона) и круга отдельно
                    local is_triangle_hovered = false
                    local is_circle_hovered = false
                    if is_hovered then
                        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                        
                        if send_states[selected_track_index][i] then
                            -- Для активного сенда проверяем области шеврона и круга
                            local radius = KNOB_SIZE/2 - 2
                            local arrow_height = radius * 0.5
                            local arrow_half_base = arrow_height * 0.9
                            local arrow_top_y = cy - radius - arrow_height - 5
                            
                            -- Проверяем hover для треугольника (шеврона)
                            local triangle_area = {
                                x = cx - arrow_half_base, 
                                y = arrow_top_y, 
                                w = arrow_half_base * 2, 
                                h = arrow_height
                            }
                            if mouse_x >= triangle_area.x and mouse_x <= triangle_area.x + triangle_area.w and
                               mouse_y >= triangle_area.y and mouse_y <= triangle_area.y + triangle_area.h then
                                is_triangle_hovered = true
                            end
                            
                            -- Проверяем hover для круга (исключая область треугольника)
                            local distance_to_center = math.sqrt((mouse_x - cx)^2 + (mouse_y - cy)^2)
                            if distance_to_center <= radius and not is_triangle_hovered then
                                is_circle_hovered = true
                            end
                        else
                            -- Для неактивного сенда проверяем область обычного треугольника
                            local triangle_size = ICON_SIZE * 0.75
                            local triangle_half = triangle_size * 0.5
                            local triangle_height = triangle_size * 0.8
                            if mouse_x >= cx - triangle_half and mouse_x <= cx + triangle_half and
                               mouse_y >= cy - 2 - triangle_height/2 and mouse_y <= cy - 2 + triangle_height/2 then
                                is_triangle_hovered = true
                            end
                        end
                    end
                    
                    -- Определяем, нужно ли показывать dB
                    local show_db = false
                    local current_time = reaper.time_precise()
                    
                    -- Создаем ключ для таблицы таймеров
                    local timer_key = selected_track_index .. "_" .. i
                    
                    -- Проверяем, активно ли перетаскивание именно для этого кольца
                    local is_this_ring_dragging = send_mouse_dragging and send_mouse_dragging_track == i
                    
                    -- Показываем dB при взаимодействии с конкретным сендом или в течение времени после взаимодействия
                    if is_this_ring_dragging or (send_db_show_timer[timer_key] and current_time < send_db_show_timer[timer_key]) then
                        show_db = true
                    end
                    
                    -- Используем новую функцию для рисования
                    local control_areas = draw_send_ring_control(ctx, cx, cy, KNOB_SIZE, 
                        send_levels[selected_track_index][i] or DEFAULT_SEND_LEVEL, 
                        send_states[selected_track_index][i] or false,
                        is_triangle_hovered, is_circle_hovered, show_db)
                    
                    -- Дополнительная проверка клика по треугольнику на уровне окна
                    if reaper.ImGui_IsWindowHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 0) and can_send then
                        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                        
                        if control_areas and control_areas.triangle_area then
                            -- Есть сенд - проверяем клик по треугольнику удаления
                            local triangle = control_areas.triangle_area
                            if mouse_x >= triangle.x and mouse_x <= triangle.x + triangle.w and
                               mouse_y >= triangle.y and mouse_y <= triangle.y + triangle.h then
                                triangle_clicked = true
                                send_icon_clicked = true
                                -- Удаляем сенд или сайдчейн
                                if real_has_send then
                                    local send_idx = track_has_send(from_track, dest_track)
                                    local sidechain_idx = track_has_sidechain(from_track, dest_track)
                                    
                                    if send_idx then
                                        reaper.RemoveTrackSend(from_track, 0, send_idx)
                                    elseif sidechain_idx then
                                        reaper.RemoveTrackSend(from_track, 0, sidechain_idx)
                                    end
                                end
                                send_states[selected_track_index][i] = false
                                update_guid_tables_for_send(selected_track_index, i, nil, false)
                            end
                        else
                            -- Нет сенда - проверяем клик по обычному треугольнику
                            local triangle_size = ICON_SIZE * 0.75
                            local triangle_half = triangle_size * 0.5
                            local triangle_height = triangle_size * 0.8
                            local triangle_x = cx
                            local triangle_y = cy - 2
                            
                            if mouse_x >= triangle_x - triangle_half and mouse_x <= triangle_x + triangle_half and
                               mouse_y >= triangle_y - triangle_height/2 and mouse_y <= triangle_y + triangle_height/2 then
                                triangle_clicked = true
                                send_icon_clicked = true
                                -- Создаем сенд при клике по треугольнику неназначенного трека
                                if not send_states[selected_track_index][i] then
                                    reaper.CreateTrackSend(from_track, dest_track)
                                    send_states[selected_track_index][i] = true
                                    send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                                    update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                                    
                                    -- Устанавливаем уровень в Reaper
                                    local send_idx = track_has_send(from_track, dest_track)
                                    if send_idx then
                                        local level_db = DEFAULT_SEND_LEVEL * 72 - 60  -- 0.833 -> 0 dB
                                        local volume_value = 10 ^ (level_db / 20)
                                        reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                    end
                                end
                            end
                        end
                    end
                    
                    if reaper.ImGui_IsItemClicked(ctx) and can_send then
                        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                        send_icon_clicked = true
                        
                        local clicked_on_triangle = false
                        
                        if control_areas and control_areas.triangle_area then
                            -- Есть сенд - проверяем клик по треугольнику удаления
                            local triangle = control_areas.triangle_area
                            if mouse_x >= triangle.x and mouse_x <= triangle.x + triangle.w and
                               mouse_y >= triangle.y and mouse_y <= triangle.y + triangle.h then
                                clicked_on_triangle = true
                                triangle_clicked = true  -- Устанавливаем флаг клика по треугольнику
                                -- Удаляем сенд или сайдчейн
                                if real_has_send then
                                    local send_idx = track_has_send(from_track, dest_track)
                                    local sidechain_idx = track_has_sidechain(from_track, dest_track)
                                    
                                    if send_idx then
                                        reaper.RemoveTrackSend(from_track, 0, send_idx)
                                    elseif sidechain_idx then
                                        reaper.RemoveTrackSend(from_track, 0, sidechain_idx)
                                    end
                                end
                                send_states[selected_track_index][i] = false
                                update_guid_tables_for_send(selected_track_index, i, nil, false)
                            end
                        else
                            -- Нет сенда - проверяем клик по обычному треугольнику
                            -- Треугольник находится в центре иконки
                            local triangle_size = ICON_SIZE * 0.75
                            local triangle_half = triangle_size * 0.5
                            local triangle_height = triangle_size * 0.8
                            local triangle_x = cx
                            local triangle_y = cy - 2
                            
                            if mouse_x >= triangle_x - triangle_half and mouse_x <= triangle_x + triangle_half and
                               mouse_y >= triangle_y - triangle_height/2 and mouse_y <= triangle_y + triangle_height/2 then
                                clicked_on_triangle = true
                                triangle_clicked = true  -- Устанавливаем флаг клика по треугольнику
                                -- Создаем сенд при клике по треугольнику неназначенного трека
                                if not send_states[selected_track_index][i] then
                                    reaper.CreateTrackSend(from_track, dest_track)
                                    send_states[selected_track_index][i] = true
                                    send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                                    update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                                    
                                    -- Устанавливаем уровень в Reaper
                                    local send_idx = track_has_send(from_track, dest_track)
                                    if send_idx then
                                        local level_db = DEFAULT_SEND_LEVEL * 72 - 60  -- 0.833 -> 0 dB
                                        local volume_value = 10 ^ (level_db / 20)
                                        reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                    end
                                end
                            end
                        end
                        
                        -- Если клик НЕ по треугольнику, но есть кольцо - создаем сенд
                        if not clicked_on_triangle and control_areas and control_areas.ring_area then
                            if not send_states[selected_track_index][i] then
                                reaper.CreateTrackSend(from_track, dest_track)
                                send_states[selected_track_index][i] = true
                                send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                                update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                                
                                -- Устанавливаем уровень в Reaper
                                local send_idx = track_has_send(from_track, dest_track)
                                if send_idx then
                                    local level_db = DEFAULT_SEND_LEVEL * 72 - 60  -- 0.833 -> 0 dB
                                    local volume_value = 10 ^ (level_db / 20)
                                    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                end
                            end
                            -- Устанавливаем таймер для показа dB при клике по кольцо
                            send_db_show_timer[timer_key] = reaper.time_precise() + send_db_show_duration
                        end
                    end
                    
                    -- Обработка вертикального перетаскивания для изменения уровня сенда
                    if control_areas and control_areas.ring_area then
                        local current_level = send_levels[selected_track_index][i] or 0
                        
                        -- Начинаем перетаскивание при клике и если еще ничего не перетаскиваем
                        if reaper.ImGui_IsItemClicked(ctx, 0) and not send_mouse_dragging then
                            send_mouse_dragging = true
                            send_mouse_dragging_track = i  -- Запоминаем какой трек перетаскиваем
                            send_mouse_start_x, send_mouse_start_y = reaper.GetMousePosition()
                            send_mouse_start_value = current_level
                            -- Устанавливаем таймер для показа dB
                            send_db_show_timer[timer_key] = reaper.time_precise() + send_db_show_duration
                        end
                        
                        -- Обновляем значение во время перетаскивания только для активного кольца
                        if send_mouse_dragging and send_mouse_dragging_track == i and reaper.ImGui_IsMouseDown(ctx, 0) then
                            -- Скрываем курсор мыши при регулировке
                            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
                            
                            local _, my = reaper.GetMousePosition()
                            local dy = my - send_mouse_start_y
                            local sensitivity = 0.0015  -- Чувствительность уровня 2 из 10 для максимально точного контроля
                            local new_level = send_mouse_start_value - dy * sensitivity  -- Минус, чтобы вверх увеличивало
                            new_level = math.max(0, math.min(1, new_level))
                            
                            send_levels[selected_track_index][i] = new_level
                            update_guid_tables_for_send(selected_track_index, i, new_level, nil)
                            
                            -- Обновляем реальный уровень сенда в Reaper
                            if send_states[selected_track_index][i] then
                                local send_idx = track_has_send(from_track, dest_track)
                                if send_idx then
                                    -- Преобразуем нормализованное значение в dB (-60 до +12)
                                    local level_db = new_level * 72 - 60  -- 0-1 -> -60 до +12 dB
                                    local volume_value = 10 ^ (level_db / 20)  -- Преобразуем dB в линейное значение
                                    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                end
                            end
                        end
                        
                        -- Заканчиваем перетаскивание при отпускании мыши
                        if send_mouse_dragging and send_mouse_dragging_track == i and not reaper.ImGui_IsMouseDown(ctx, 0) then
                            send_mouse_dragging = false
                            send_mouse_dragging_track = nil
                            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
                        end
                    end
                     
                     -- Поддержка колесика мыши для точного управления
                     if control_areas and control_areas.ring_area and reaper.ImGui_IsItemHovered(ctx) then
                         local wheel_y = reaper.ImGui_GetMouseWheel(ctx)
                         if wheel_y and wheel_y ~= 0 then
                             local current_level = send_levels[selected_track_index][i] or 0
                             local delta = wheel_y * 0.02  -- Чувствительность колесика
                             local new_level = math.max(0, math.min(1, current_level + delta))
                             
                             send_levels[selected_track_index][i] = new_level
                             update_guid_tables_for_send(selected_track_index, i, new_level, nil)
                             
                             -- Устанавливаем таймер для показа dB
                             send_db_show_timer[timer_key] = reaper.time_precise() + send_db_show_duration
                             
                             -- Обновляем реальный уровень сенда в Reaper
                             if send_states[selected_track_index][i] then
                                 local send_idx = track_has_send(from_track, dest_track)
                                 if send_idx then
                                     local level_db = new_level * 72 - 60  -- 0-1 -> -60 до +12 dB
                                     local volume_value = 10 ^ (level_db / 20)
                                     reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                 end
                             end
                         end
                     end
                    
                    -- Контекстное меню для сенда при правом клике на кольцо
                    if control_areas and control_areas.ring_area and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) and send_states[selected_track_index][i] then
                        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                        local clicked_on_ring = false
                        
                        -- Проверяем клик по кольцу (не по треугольнику)
                        if control_areas.ring_area then
                            local ring = control_areas.ring_area
                            if mouse_x >= ring.x and mouse_x <= ring.x + ring.w and
                               mouse_y >= ring.y and mouse_y <= ring.y + ring.h then
                                -- Дополнительно проверяем, что клик НЕ по треугольнику
                                if control_areas.triangle_area then
                                    local triangle = control_areas.triangle_area
                                    if not (mouse_x >= triangle.x and mouse_x <= triangle.x + triangle.w and
                                           mouse_y >= triangle.y and mouse_y <= triangle.y + triangle.h) then
                                        clicked_on_ring = true
                                    end
                                else
                                    clicked_on_ring = true
                                end
                            end
                        end
                        
                        if clicked_on_ring then
                            send_icon_clicked = true
                            reaper.ImGui_OpenPopup(ctx, "SendMenu_"..i)
                        end
                    end
                    
                    -- Отображение контекстного меню сенда
                    if reaper.ImGui_BeginPopup(ctx, "SendMenu_"..i) then
                        if reaper.ImGui_Selectable(ctx, "Reset") then
                            send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Значение по умолчанию
                            update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, nil)
                            -- Обновляем реальный уровень сенда в Reaper
                            if send_states[selected_track_index][i] then
                                local send_idx = track_has_send(from_track, dest_track)
                                if send_idx then
                                    local level_db = DEFAULT_SEND_LEVEL * 72 - 60  -- 0dB
                                    local volume_value = 10 ^ (level_db / 20)
                                    reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                end
                            end
                        end
                        
                        if reaper.ImGui_Selectable(ctx, "Copy Value") then
                            -- Конвертируем уровень сенда в dB для совместимости с громкостью
                            local current_level = send_levels[selected_track_index][i] or DEFAULT_SEND_LEVEL
                            copied_value_db = current_level * 72 - 60  -- Конвертируем в dB
                        end
                        
                        -- Paste Value - активно только если есть скопированное значение
                        if copied_value_db then
                            if reaper.ImGui_Selectable(ctx, "Paste Value") then
                                -- Конвертируем dB обратно в уровень сенда (0.0-1.0)
                                local send_level = (copied_value_db + 60) / 72
                                send_level = math.max(0.0, math.min(1.0, send_level))  -- Ограничиваем диапазон
                                send_levels[selected_track_index][i] = send_level
                                update_guid_tables_for_send(selected_track_index, i, send_level, nil)
                                -- Обновляем реальный уровень сенда в Reaper
                                if send_states[selected_track_index][i] then
                                    local send_idx = track_has_send(from_track, dest_track)
                                    if send_idx then
                                        local volume_value = 10 ^ (copied_value_db / 20)
                                        reaper.SetTrackSendInfo_Value(from_track, 0, send_idx, "D_VOL", volume_value)
                                    end
                                end
                            end
                        else
                            -- Неактивный пункт меню
                            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                            reaper.ImGui_Selectable(ctx, "Paste Value", false, reaper.ImGui_SelectableFlags_Disabled())
                            reaper.ImGui_PopStyleColor(ctx, 1)
                        end
                        
                        reaper.ImGui_EndPopup(ctx)
                    end
                    
                    -- Контекстное меню роутинга появляется только при правом клике по треугольнику
                    if can_send and reaper.ImGui_IsItemClicked(ctx, 1) then
                        local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                        local clicked_on_triangle = false
                        
                        if control_areas and control_areas.triangle_area then
                            -- Есть сенд - проверяем клик по треугольнику удаления
                            local triangle = control_areas.triangle_area
                            if mouse_x >= triangle.x and mouse_x <= triangle.x + triangle.w and
                               mouse_y >= triangle.y and mouse_y <= triangle.y + triangle.h then
                                clicked_on_triangle = true
                            end
                        else
                            -- Нет сенда - проверяем клик по обычному треугольнику
                            local triangle_size = ICON_SIZE * 0.75
                            local triangle_half = triangle_size * 0.5
                            local triangle_height = triangle_size * 0.8
                            local triangle_x = cx
                            local triangle_y = cy - 2
                            
                            if mouse_x >= triangle_x - triangle_half and mouse_x <= triangle_x + triangle_half and
                               mouse_y >= triangle_y - triangle_height/2 and mouse_y <= triangle_y + triangle_height/2 then
                                clicked_on_triangle = true
                            end
                        end
                        
                        -- Открываем контекстное меню только если клик был по треугольнику
                        if clicked_on_triangle then
                            send_icon_clicked = true
                            reaper.ImGui_OpenPopup(ctx, "RoutingMenu_"..i)
                        end
                    end
                    if reaper.ImGui_BeginPopup(ctx, "RoutingMenu_"..i) then
                        if reaper.ImGui_Selectable(ctx, "Route to this track") then
                            create_normal_send(from_track, dest_track, false)
                            send_states[selected_track_index][i] = true
                            send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                            update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                        end
                        if reaper.ImGui_Selectable(ctx, "Route to this track only") then
                            create_normal_send(from_track, dest_track, true)
                            send_states[selected_track_index][i] = true
                            send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                            update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                        end
                        if reaper.ImGui_Selectable(ctx, "Sidechain to this track") then
                            create_sidechain_send(from_track, dest_track, false)
                            send_states[selected_track_index][i] = true
                            send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                            update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                        end
                        if reaper.ImGui_Selectable(ctx, "Sidechain to this track only") then
                            create_sidechain_send(from_track, dest_track, true)
                            send_states[selected_track_index][i] = true
                            send_levels[selected_track_index][i] = DEFAULT_SEND_LEVEL  -- Устанавливаем уровень по умолчанию
                            update_guid_tables_for_send(selected_track_index, i, DEFAULT_SEND_LEVEL, true)
                        end
                        reaper.ImGui_EndPopup(ctx)
                    end
                end
            end

            -- Добавляем дополнительное пространство под сендами для лучшей отрисовки линий
            local y_cursor = reaper.ImGui_GetCursorPosY(ctx)
            local free_space = height - y_cursor - ICON_SIZE - 66  -- Увеличено с 36 до 66 для большего места под сендами
            
            -- Добавляем минимальное пространство для отрисовки линий
            local min_space_for_lines = 120 -- Увеличено с 80 до 120 для максимального места под линиями сендов
            free_space = math.max(free_space, min_space_for_lines)
            
            -- Невидимая зона для выделения и вызова контекстного меню
            if free_space > 0 then
                reaper.ImGui_PushID(ctx, i)
                if reaper.ImGui_InvisibleButton(ctx, "track_area", width, free_space) and not ctrl_drag_active then
                    local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
                    set_selected_track(i, ctrl_held)
                end
                if reaper.ImGui_IsItemClicked(ctx, 1) and not ctrl_drag_active then
                    set_selected_track(i, false)
                end
                if reaper.ImGui_BeginPopupContextItem(ctx, "track_ctx_"..i) then
                    local track = (i == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i-1)
                    draw_track_context_menu(i, track)
                    reaper.ImGui_EndPopup(ctx)
                end
                reaper.ImGui_PopID(ctx)
            end

            -- Если клик по child (любая зона кроме send icon, треугольника и FX кнопки), выделить трек
            if reaper.ImGui_IsWindowHovered(ctx)
                and reaper.ImGui_IsMouseClicked(ctx, 0)
                and not send_icon_clicked -- не по send icon
                and not triangle_clicked -- не по треугольнику
                and not fx_button_clicked -- не по FX кнопке
                and not ctrl_drag_active -- не во время Ctrl + перетаскивание
            then
                local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
                set_selected_track(i, ctrl_held)
            end
            
            -- Обработка правого клика по области трека
            if reaper.ImGui_IsWindowHovered(ctx)
                and reaper.ImGui_IsMouseClicked(ctx, 1)
                and not send_icon_clicked
                and not triangle_clicked
                and not fx_button_clicked
                and not pan_right_clicked
                and not stereo_right_clicked
                and not volume_right_clicked
                and not ctrl_drag_active then
                set_selected_track(i, false)
                reaper.ImGui_OpenPopup(ctx, "track_ctx_"..i)
            end

            if track_child_open then
                reaper.ImGui_EndChild(ctx)
            end
            
            -- Размещаем треки в ряд
            if i < track_count then
                reaper.ImGui_SameLine(ctx, 0, 0)  -- Используем нулевой отступ, так как отступы уже настроены через ItemSpacing
            end
        end

        -- Автоскролл при Ctrl+drag выделении
        if ctrl_drag_active and ctrl_held and mouse_down and need_scroll and child_window_open then
            local scroll_margin = 50  -- Отступ от края для начала скролла
            local scroll_speed = 10   -- Скорость скролла
            
            -- Получаем позицию и размеры окна скролла
            local scroll_x, scroll_y = reaper.ImGui_GetWindowPos(ctx)
            local scroll_w, scroll_h = reaper.ImGui_GetWindowSize(ctx)
            
            -- Проверяем, находится ли мышь близко к левому или правому краю
            local relative_mouse_x = mouse_x - scroll_x
            
            if relative_mouse_x < scroll_margin then
                -- Мышь близко к левому краю - скроллим влево
                local current_scroll = reaper.ImGui_GetScrollX(ctx)
                local new_scroll = math.max(0, current_scroll - scroll_speed)
                reaper.ImGui_SetScrollX(ctx, new_scroll)
            elseif relative_mouse_x > (scroll_w - scroll_margin) then
                -- Мышь близко к правому краю - скроллим вправо
                local current_scroll = reaper.ImGui_GetScrollX(ctx)
                local max_scroll = reaper.ImGui_GetScrollMaxX(ctx)
                local new_scroll = math.min(max_scroll, current_scroll + scroll_speed)
                reaper.ImGui_SetScrollX(ctx, new_scroll)
            end
        end

        -- Автоскролл к перемещенному треку (Shift+колесо мыши)
        if track_move_autoscroll_target and need_scroll and child_window_open then
            local target_track_idx = track_move_autoscroll_target
            
            -- Вычисляем позицию целевого трека
            local target_x = 0
            for j = 0, target_track_idx - 1 do
                local j_width = (j == 0) and MASTER_WIDTH or CHANNEL_WIDTH
                target_x = target_x + j_width + 1  -- +1 для spacing
            end
            
            -- Получаем текущую позицию скролла и размеры окна
            local current_scroll = reaper.ImGui_GetScrollX(ctx)
            local scroll_w, scroll_h = reaper.ImGui_GetWindowSize(ctx)
            local visible_left = current_scroll
            local visible_right = current_scroll + scroll_w
            
            -- Ширина целевого трека
            local target_width = (target_track_idx == 0) and MASTER_WIDTH or CHANNEL_WIDTH
            
            -- Проверяем, виден ли трек полностью
            if target_x < visible_left or (target_x + target_width) > visible_right then
                -- Центрируем трек в окне
                local new_scroll = target_x - (scroll_w - target_width) / 2
                local max_scroll = reaper.ImGui_GetScrollMaxX(ctx)
                new_scroll = math.max(0, math.min(max_scroll, new_scroll))
                reaper.ImGui_SetScrollX(ctx, new_scroll)
            end
            
            -- Сбрасываем цель автоскролла
            track_move_autoscroll_target = nil
        end

        -- Рисуем линии сендов/сайдчейнов (Bezier curves) в стиле FL Studio
        if selected_track_index > 0 then
            local from_idx = selected_track_index
            local from_track = reaper.GetTrack(0, from_idx-1)
            
            -- Сначала рисуем линии между треками (не к мастеру)
            for to_idx = 1, track_count do
                if to_idx ~= from_idx then
                    local dest_track = reaper.GetTrack(0, to_idx-1)
                    local from_icon = icon_centers[from_idx]
                    local to_icon = icon_centers[to_idx]
                    if from_icon and to_icon then
                        local send_idx = track_has_send(from_track, dest_track)
                        local sc_idx = track_has_sidechain(from_track, dest_track)
                        
                        -- Определяем направление линии (слева направо или справа налево)
                        local is_left_to_right = from_icon.x < to_icon.x
                        
                        -- Вычисляем контрольные точки для более плавных кривых в стиле FL Studio
                        local distance = math.abs(from_icon.x - to_icon.x)
                        local curve_height = math.min(distance * 0.5, 120) -- Ограничиваем высоту кривой
                        
                        if send_idx and not sc_idx then
                            -- Обычный сенд - зеленая линия
                            local cp_y = math.max(from_icon.y, to_icon.y) + 45
                            reaper.ImGui_DrawList_AddBezierCubic(
                                reaper.ImGui_GetWindowDrawList(ctx),
                                from_icon.x, from_icon.y,
                                from_icon.x, cp_y,
                                to_icon.x, cp_y,
                                to_icon.x, to_icon.y,
                                COLOR_ACTIVE, 2.5
                            )
                        end
                        
                        if sc_idx then
                            -- Сайдчейн - оранжевая линия
                            local cp_y = math.max(from_icon.y, to_icon.y) + 45
                            reaper.ImGui_DrawList_AddBezierCubic(
                                reaper.ImGui_GetWindowDrawList(ctx),
                                from_icon.x, from_icon.y,
                                from_icon.x, cp_y,
                                to_icon.x, cp_y,
                                to_icon.x, to_icon.y,
                                COLOR_SIDECHAIN, 2.5
                            )
                        end
                    end
                end
            end
            
            -- Отдельно рисуем линию к мастеру
            if track_routed_to_master(from_track) then
                local from_icon = icon_centers[from_idx]
                local to_icon = icon_centers[0] -- Мастер-трек имеет индекс 0
                if from_icon and to_icon then
                    -- Маршрутизация на мастер - более толстая зеленая линия
                    local cp_y = math.max(from_icon.y, to_icon.y) + 105
                    reaper.ImGui_DrawList_AddBezierCubic(
                        reaper.ImGui_GetWindowDrawList(ctx),
                        from_icon.x, from_icon.y,
                        from_icon.x, cp_y,
                        to_icon.x, cp_y,
                        to_icon.x, to_icon.y,
                        COLOR_ACTIVE, 3
                    )
                end
            end
        end

        -- Всегда вызываем PopStyleVar, независимо от условия need_scroll
        reaper.ImGui_PopStyleVar(ctx, 1)  -- Явно указываем количество
        
        -- EndChild вызываем только если BeginChild вернул true
        if child_window_open then
            reaper.ImGui_EndChild(ctx)
        end
        
        -- === FX Chain Panel ===
        -- FX панель всегда видна справа
        reaper.ImGui_SameLine(ctx)
        
        -- Создаем область для FX панели без использования child window
        local fx_panel_x, fx_panel_y = reaper.ImGui_GetCursorPos(ctx)
        
        -- Устанавливаем позицию для FX панели
        reaper.ImGui_SetCursorPos(ctx, fx_panel_x, fx_panel_y)
        
        -- Рисуем фон для FX панели
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local panel_min_x, panel_min_y = reaper.ImGui_GetCursorScreenPos(ctx)
        local panel_max_x = panel_min_x + fx_panel_width
        local panel_max_y = panel_min_y + available_height
        reaper.ImGui_DrawList_AddRectFilled(dl, panel_min_x, panel_min_y, panel_max_x, panel_max_y, 0x1A1A1AFF)
        reaper.ImGui_DrawList_AddRect(dl, panel_min_x, panel_min_y, panel_max_x, panel_max_y, 0x404040FF, 0, 0, 1)
        
        -- Создаем группу для содержимого FX панели
        reaper.ImGui_BeginGroup(ctx)
        
        -- Заголовок FX панели
        reaper.ImGui_PushFont(ctx, font_small)
        reaper.ImGui_Text(ctx, "FX Chain")
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_Separator(ctx)
        
        local track = selected_track
        if track then
            -- Обновляем виртуальное маппинг для текущего трека
            update_virtual_mapping(track)
            local mapping = get_virtual_mapping(track)
            
            -- Устанавливаем стиль для уменьшения промежутков между элементами
            reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0, 0)
            
            -- Сбрасываем целевой слот в начале кадра только если не перетаскиваем
            if not fx_drag_source then
                fx_hover_target = nil
            end
            
            -- Рисуем 10 виртуальных слотов для эффектов
            for slot = 1, 10 do
                local real_fx_idx = mapping[slot]  -- Получаем реальный индекс FX для этого виртуального слота
                local has_fx = real_fx_idx ~= nil
                
                -- Размеры слота (компактные)
                local slot_width = fx_panel_width
                local slot_height = 18
                
                -- Получаем позицию курсора и экранные координаты слота
                local cursor_x, cursor_y = reaper.ImGui_GetCursorPos(ctx)
                local screen_x, screen_y = reaper.ImGui_GetCursorScreenPos(ctx)
                
                -- Цвета для слота
                local slot_bg_color = has_fx and 0x2D2D30FF or 0x1E1E1EFF
                local slot_border_color = has_fx and 0x007ACC80 or 0x3C3C3CFF
                local text_color = has_fx and 0xFFFFFFFF or 0x808080FF
                
                -- Рисуем фон слота
                local dl = reaper.ImGui_GetWindowDrawList(ctx)
                reaper.ImGui_DrawList_AddRectFilled(dl, screen_x, screen_y, screen_x + slot_width, screen_y + slot_height, slot_bg_color, 3)
                reaper.ImGui_DrawList_AddRect(dl, screen_x, screen_y, screen_x + slot_width, screen_y + slot_height, slot_border_color, 3, 0, 1)
                if fx_dragging and fx_drag_source == slot then
                    reaper.ImGui_DrawList_AddRect(dl, screen_x, screen_y, screen_x + slot_width, screen_y + slot_height, 0xFFFFFF80, 3)
                end
                -- Mix knob (слева от индикатора активности)
                if has_fx then
                    local track_guid = reaper.GetTrackGUID(track)
                    if not fx_mix_values[track_guid] then
                        fx_mix_values[track_guid] = {}
                    end
                    if not fx_mix_values[track_guid][real_fx_idx] then
                        -- Пытаемся получить текущее значение wet параметра из FX
                        local mix_param = reaper.TrackFX_GetParamFromIdent(track, real_fx_idx, ":wet")
                        if mix_param >= 0 then
                            fx_mix_values[track_guid][real_fx_idx] = reaper.TrackFX_GetParam(track, real_fx_idx, mix_param)
                        else
                            fx_mix_values[track_guid][real_fx_idx] = 0.0  -- По умолчанию 0% если wet параметр не найден
                        end
                    end

                    -- Позиционируем mix knob в layout
                    local mix_knob_size = 20
                    local mix_knob_offset_x = slot_width - 35  -- Слева от индикатора
                    local mix_knob_offset_y = (slot_height - mix_knob_size) / 2
                    
                    -- Сохраняем текущую позицию курсора
                    local saved_cursor_x, saved_cursor_y = reaper.ImGui_GetCursorPos(ctx)
                    
                    -- Устанавливаем курсор для mix knob
                    reaper.ImGui_SetCursorPos(ctx, cursor_x + mix_knob_offset_x, cursor_y + mix_knob_offset_y)

                    local mix_changed, new_mix_value, mix_right_clicked = small_mix_knob(ctx, 0, 0, mix_knob_size,
                        fx_mix_values[track_guid][real_fx_idx], 0.0, 1.0, "mix_" .. slot)

                    -- Восстанавливаем позицию курсора
                    reaper.ImGui_SetCursorPos(ctx, saved_cursor_x, saved_cursor_y)

                    if mix_changed then
                        fx_mix_values[track_guid][real_fx_idx] = new_mix_value
                        -- Применяем Mix параметр к FX через wet параметр
                        local mix_param = reaper.TrackFX_GetParamFromIdent(track, real_fx_idx, ":wet")
                        if mix_param >= 0 then
                            reaper.TrackFX_SetParam(track, real_fx_idx, mix_param, new_mix_value)
                        end
                    end
                end
                
                -- Индикатор активности (справа)
                local indicator_x = screen_x + slot_width - 10
                local indicator_y = screen_y + 9
                local indicator_color = 0x404040FF
                local enabled = false
                
                if has_fx then
                    enabled = reaper.TrackFX_GetEnabled(track, real_fx_idx)
                    indicator_color = enabled and 0x00FF00FF or 0x808080FF  -- Зеленый когда включен, серый когда выключен
                end
                
                reaper.ImGui_DrawList_AddCircleFilled(dl, indicator_x, indicator_y, 3, indicator_color)
                
                -- Невидимая кнопка для обработки кликов
                reaper.ImGui_SetCursorPos(ctx, cursor_x, cursor_y)
                reaper.ImGui_InvisibleButton(ctx, "slot_" .. slot, slot_width, slot_height)
                is_slot_hovered = reaper.ImGui_IsItemHovered(ctx)
                slot_clicked_left = reaper.ImGui_IsItemClicked(ctx, 0)
                slot_clicked_right = reaper.ImGui_IsItemClicked(ctx, 1)
                
                -- Получаем координаты мыши и области
                mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
                mouse_x = mouse_x - screen_x  -- Относительно слота
                indicator_area_start = slot_width - 20  -- Область индикатора
                mix_area_start = slot_width - 40  -- Область mix knob
                
                -- Отображаем текст поверх слота используя координаты экрана
                -- Номер слота (слева)
                reaper.ImGui_PushFont(ctx, font_small)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                reaper.ImGui_DrawList_AddText(dl, screen_x + 3, screen_y + 2, 0x808080FF, "Slot " .. slot)
                reaper.ImGui_PopStyleColor(ctx)
                reaper.ImGui_PopFont(ctx)
                
                -- Отображаем название FX если есть
                if has_fx then
                    local retval, fx_name = reaper.TrackFX_GetFXName(track, real_fx_idx, "")
                    fx_name = RemoveVSTVersion(fx_name)  -- Убираем версию VST
                    -- Укорачиваем название если слишком длинное
                    if string.len(fx_name) > 26 then
                        fx_name = string.sub(fx_name, 1, 23) .. "..."
                    end
                    
                    reaper.ImGui_PushFont(ctx, font_small)
                    reaper.ImGui_DrawList_AddText(dl, screen_x + 3, screen_y + 2, text_color, fx_name)
                    reaper.ImGui_PopFont(ctx)
                end
                -- Обрабатываем клики только если есть FX
                if has_fx and is_slot_hovered then

                    -- Клик по индикатору активности
                    if slot_clicked_left and mouse_x >= indicator_area_start then
                        reaper.TrackFX_SetEnabled(track, real_fx_idx, not enabled)
                    -- Клик по основной области слота (не Mix knob и не индикатор)
                    elseif slot_clicked_left and mouse_x < mix_area_start then
                        -- Начинаем потенциальное перетаскивание
                        fx_drag_source = slot
                        fx_drag_start_x, fx_drag_start_y = reaper.ImGui_GetMousePos(ctx)
                        fx_dragging = false
                        fx_click_candidate = slot
                    elseif slot_clicked_right and mouse_x < mix_area_start then
                        -- Контекстное меню для FX
                        reaper.ImGui_OpenPopup(ctx, "fx_context_" .. slot)
                    end
                elseif (slot_clicked_left or slot_clicked_right) and not has_fx then
                    if slot_clicked_left then
                        -- Открываем FX браузер для добавления нового FX в выбранный слот
                        -- Сохраняем номер слота и трек для последующего использования
                        target_slot_for_new_fx = slot

                        target_track_for_new_fx = fx_panel_track  -- Сохраняем трек, для которого отображается FX панель

                        -- Обновляем выбранный трек в Reaper перед открытием браузера
                        if fx_panel_track then
                            -- Правильно устанавливаем фокус для любого трека
                            reaper.SetOnlyTrackSelected(fx_panel_track)
                            reaper.CSurf_OnTrackSelection(fx_panel_track)
                        end

                        -- Открываем FX браузер через команду действия
                        reaper.Main_OnCommand(40271, 0)  -- Track: View FX browser
                    elseif slot_clicked_right then
                        -- Контекстное меню для пустого слота
                        reaper.ImGui_OpenPopup(ctx, "fx_context_" .. slot)
                    end
                end
                
                -- Обработка колесика мыши для перемещения эффектов
                if is_slot_hovered and mouse_x < mix_area_start then
                    local wheel_y = reaper.ImGui_GetMouseWheel(ctx)
                    if wheel_y ~= 0 then
                        if wheel_y > 0 and slot > 1 then
                            -- Прокрутка вверх - перемещаем эффект вверх
                            move_fx_in_virtual_slots(track, slot, slot - 1)
                        elseif wheel_y < 0 and slot < 10 then
                            -- Прокрутка вниз - перемещаем эффект вниз
                            move_fx_in_virtual_slots(track, slot, slot + 1)
                        end
                    end
                end
                
                -- Контекстное меню для FX (заполненных и пустых слотов)
                if reaper.ImGui_BeginPopup(ctx, "fx_context_" .. slot) then
                    if has_fx then
                        -- Меню для заполненного слота
                        local retval, fx_name = reaper.TrackFX_GetFXName(track, real_fx_idx, "")
                        fx_name = RemoveVSTVersion(fx_name)  -- Убираем версию VST
                        local enabled = reaper.TrackFX_GetEnabled(track, real_fx_idx)
                        
                        reaper.ImGui_Text(ctx, fx_name)
                        reaper.ImGui_Separator(ctx)
                        
                        if reaper.ImGui_MenuItem(ctx, "Copy plugin") then
                            copy_plugin(track, real_fx_idx)
                        end
                        
                        local can_paste_plugin = copied_plugin_data ~= nil
                        if can_paste_plugin then
                            if reaper.ImGui_MenuItem(ctx, "Paste plugin") then
                                -- Заменяем плагин в текущем слоте
                                reaper.Undo_BeginBlock()
                                
                                -- Удаляем существующий FX
                                reaper.TrackFX_Delete(track, real_fx_idx)
                                
                                -- Добавляем скопированный FX в указанную позицию
                                local new_fx_idx = reaper.TrackFX_AddByName(track, copied_plugin_data.name, false, real_fx_idx)
                                if new_fx_idx >= 0 then
                                    reaper.TrackFX_SetEnabled(track, new_fx_idx, copied_plugin_data.enabled)
                                    
                                    -- Восстанавливаем параметры
                                    if copied_plugin_data.params then
                                        for param_idx, param_value in pairs(copied_plugin_data.params) do
                                            reaper.TrackFX_SetParam(track, new_fx_idx, param_idx, param_value)
                                        end
                                    end
                                    
                                    -- Устанавливаем пресет (если есть)
                                    if copied_plugin_data.preset and copied_plugin_data.preset ~= "" then
                                        reaper.TrackFX_SetPreset(track, new_fx_idx, copied_plugin_data.preset)
                                    end
                                    
                                    -- Обновляем виртуальное маппинг
                                    mapping[slot] = new_fx_idx
                                end
                                
                                update_virtual_mapping(track)
                                reaper.Undo_EndBlock("Paste Plugin", -1)
                            end
                        else
                            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                            reaper.ImGui_MenuItem(ctx, "Paste plugin", nil, false, false)
                            reaper.ImGui_PopStyleColor(ctx, 1)
                        end
                        

                        
                        reaper.ImGui_Separator(ctx)
                        
                        if reaper.ImGui_MenuItem(ctx, "Delete") then
                            reaper.Undo_BeginBlock()
                            reaper.TrackFX_Delete(track, real_fx_idx)
                            -- Удаляем из виртуального маппинга
                            mapping[slot] = nil
                            reaper.Undo_EndBlock("Delete FX", -1)
                            SyncFXChainFromSlots(track)
                        end
                    else
                        -- Меню для пустого слота
                        reaper.ImGui_Text(ctx, "Slot " .. slot .. " (Empty)")
                        reaper.ImGui_Separator(ctx)
                        
                        if reaper.ImGui_MenuItem(ctx, "Add plugin...") then
                            -- Открываем FX браузер для добавления нового FX в выбранный слот
                            target_slot_for_new_fx = slot
                            target_track_for_new_fx = fx_panel_track
                            
                            -- Обновляем выбранный трек в Reaper перед открытием браузера
                            if fx_panel_track then
                                -- Правильно устанавливаем фокус для любого трека
                                reaper.SetOnlyTrackSelected(fx_panel_track)
                                reaper.CSurf_OnTrackSelection(fx_panel_track)
                            end
                            
                            -- Открываем FX браузер через команду действия
                            reaper.Main_OnCommand(40271, 0)  -- Track: View FX browser
                        end
                        
                        local can_paste_plugin = copied_plugin_data ~= nil
                        if can_paste_plugin then
                            if reaper.ImGui_MenuItem(ctx, "Paste plugin") then
                                -- Добавляем скопированный плагин в пустой слот
                                local new_fx_idx = reaper.TrackFX_AddByName(track, copied_plugin_data.name, false, -1)
                                if new_fx_idx >= 0 then
                                    reaper.Undo_BeginBlock()
                                    
                                    reaper.TrackFX_SetEnabled(track, new_fx_idx, copied_plugin_data.enabled)
                                    
                                    -- Восстанавливаем параметры
                                    if copied_plugin_data.params then
                                        for param_idx, param_value in pairs(copied_plugin_data.params) do
                                            reaper.TrackFX_SetParam(track, new_fx_idx, param_idx, param_value)
                                        end
                                    end
                                    
                                    -- Устанавливаем пресет (если есть)
                                    if copied_plugin_data.preset and copied_plugin_data.preset ~= "" then
                                        reaper.TrackFX_SetPreset(track, new_fx_idx, copied_plugin_data.preset)
                                    end
                                    
                                    -- Обновляем виртуальное маппинг
                                    mapping[slot] = new_fx_idx
                                    update_virtual_mapping(track)
                                    
                                    reaper.Undo_EndBlock("Paste Plugin to Empty Slot", -1)
                                end
                            end
                        else
                            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
                            reaper.ImGui_MenuItem(ctx, "Paste plugin", nil, false, false)
                            reaper.ImGui_PopStyleColor(ctx, 1)
                        end
                    end
                    
                    reaper.ImGui_EndPopup(ctx)
                end
                
                -- Устанавливаем целевой слот при перетаскивании (для любого слота)
                if fx_drag_source and is_slot_hovered then
                    fx_hover_target = slot  -- Устанавливаем целевой слот
                end
                
                -- Подсветка целевого слота при перетаскивании
                if fx_dragging and fx_hover_target == slot then
                    -- Подсветка рамки слота цветом как у линий сенда
                    reaper.ImGui_DrawList_AddRect(dl, screen_x - 1, screen_y - 1,
                        screen_x + slot_width + 1, screen_y + slot_height + 1,
                        COLOR_ACTIVE, 2, 0, 2)
                    -- Легкая подсветка фона
                    reaper.ImGui_DrawList_AddRectFilled(dl, screen_x, screen_y,
                        screen_x + slot_width, screen_y + slot_height,
                        0x91FF3320)
                elseif is_slot_hovered and not fx_dragging then
                    -- Обычный hover эффект
                    reaper.ImGui_DrawList_AddRect(dl, screen_x, screen_y,
                        screen_x + slot_width, screen_y + slot_height,
                        0xFFFFFF40, 1)
                end
                
                -- Весь лишний код удален
                
                -- Устанавливаем курсор на следующую позицию точно без промежутков
                if slot < 10 then
                    local next_y = cursor_y + slot_height
                    reaper.ImGui_SetCursorPos(ctx, cursor_x, next_y)
                end
            end

            -- Обработка состояний перетаскивания FX
            if fx_drag_source then
                if reaper.ImGui_IsMouseDown(ctx, 0) then
                    local mx, my = reaper.ImGui_GetMousePos(ctx)
                    if not fx_dragging and (math.abs(mx - fx_drag_start_x) > 2 or math.abs(my - fx_drag_start_y) > 2) then
                        fx_dragging = true
                    end
                    
                    -- Устанавливаем курсор зажатой руки во время перетаскивания
                    if fx_dragging then
                        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
                    end
                    
                    -- Определяем целевой слот по позиции мыши во время перетаскивания
                    if fx_dragging then
                        local panel_min_x, panel_min_y = reaper.ImGui_GetCursorScreenPos(ctx)
                        panel_min_y = panel_min_y - 10 * 18 - 20  -- Компенсируем высоту слотов и заголовка
                        local slot_height = 18
                        local relative_y = my - panel_min_y - 20  -- Относительно начала слотов
                        
                        if relative_y >= 0 then
                            local target_slot = math.floor(relative_y / slot_height) + 1
                            if target_slot >= 1 and target_slot <= 10 and target_slot ~= fx_drag_source then
                                if fx_hover_target ~= target_slot then
                                    fx_hover_target = target_slot
                                end
                            end
                        end
                    end
                else
                    -- Кнопка отпущена
                    if fx_dragging and fx_hover_target and fx_hover_target ~= fx_drag_source then
                        move_fx_in_virtual_slots(track, fx_drag_source, fx_hover_target)
                    elseif fx_click_candidate == fx_drag_source and not fx_dragging then
                        local real_idx = mapping[fx_drag_source]
                        if real_idx then
                            reaper.TrackFX_Show(track, real_idx, 1)
                        end
                    end
                    
                    -- Сбрасываем курсор к обычному состоянию
                    if fx_dragging then
                        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Arrow())
                    end
                    
                    fx_drag_source = nil
                    fx_dragging = false
                    fx_click_candidate = nil
                    -- НЕ сбрасываем fx_hover_target здесь
                end
            end

            -- Восстанавливаем стиль
            reaper.ImGui_PopStyleVar(ctx)
        else
            reaper.ImGui_Text(ctx, "No track selected")
            reaper.ImGui_TextWrapped(ctx, "Select a track to view its FX chain")
        end
        
        reaper.ImGui_EndGroup(ctx)
        
        reaper.ImGui_PopStyleColor(ctx, 2)  -- Явно указываем количество
        reaper.ImGui_PopFont(ctx)
    end
    
    -- Контекстные меню треков
    for i = 0, reaper.CountTracks(0) do
        if ctx and reaper.ImGui_BeginPopup(ctx, "track_ctx_"..i) then
            local track = nil
            if i == 0 then
                track = reaper.GetMasterTrack(0)
            else
                track = reaper.GetTrack(0, i-1)
            end
            draw_track_context_menu(i, track)
            reaper.ImGui_EndPopup(ctx)
        end
    end
    
    if ctx then
        reaper.ImGui_End(ctx)
    end
    
    -- Панель настроек частиц
    if ctx then
        draw_particle_settings_panel()
    end
    
    if open then
        reaper.defer(loop)
    else
        -- Очистка основного контекста
        if ctx and type(reaper.ImGui_DestroyContext) == "function" then
            reaper.ImGui_DestroyContext(ctx)
            ctx = nil
        end
        
        -- Очистка контекста частиц
        if particle_ctx and type(reaper.ImGui_DestroyContext) == "function" then
            reaper.ImGui_DestroyContext(particle_ctx)
            particle_ctx = nil
        end
    end
end

if not ctx then SetupContext() end
init_send_data()
reaper.defer(loop)