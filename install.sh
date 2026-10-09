#!/bin/bash
set -e
echo "=== Установка бота «Домик на дереве» ==="
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip >/dev/null
mkdir -p /opt/domikbot && cd /opt/domikbot
cat > bot.py <<'BOTEOF'
"""
Бот записи на экскурсию для группы ВКонтакте
детского сада «Домик на дереве» (Ижевск).

Работает через Bots Long Poll API: достаточно запустить скрипт
на любом компьютере или сервере с интернетом, белый IP не нужен.
"""

import csv
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import vk_api
from vk_api.bot_longpoll import VkBotEventType, VkBotLongPoll
from vk_api.keyboard import VkKeyboard, VkKeyboardColor
from vk_api.utils import get_random_id

# ---------- настройки (из файла .env или переменных окружения) ----------

def load_env(path=".env"):
    p = Path(__file__).with_name(path)
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

load_env()

TOKEN = os.environ["VK_GROUP_TOKEN"]
GROUP_ID = int(os.environ["VK_GROUP_ID"])
# id администраторов ВК через запятую — им придут заявки.
# Важно: каждый администратор должен хотя бы раз написать в сообщения группы.
ADMIN_IDS = [int(x) for x in os.environ.get("VK_ADMIN_IDS", "").replace(" ", "").split(",") if x]
LEADS_FILE = Path(__file__).with_name("leads.csv")
JOBS_FILE = Path(__file__).with_name("vacancies.csv")

# ---------- тексты ----------

PRICES = (
    "💰 Стоимость (абонемент на месяц):\n\n"
    "Младшая группа, 2–3 года\n"
    "• полный день — 24 000 ₽\n"
    "• неполный день — 19 000 ₽\n\n"
    "Старшая группа, 3–6 лет\n"
    "• полный день — 27 000 ₽\n"
    "• неполный день — 22 000 ₽\n\n"
    "Работаем пн–пт с 8:00 до 18:00."
)

CONTACTS = (
    "📍 Ижевск, КП «Орловское», ул. Обухова, 19\n"
    "🕗 Пн–пт, 8:00–18:00\n\n"
    "📞 Директор: +7 (922) 682-18-89\n"
    "📞 Руководитель: +7 (982) 116-00-00"
)

WELCOME = (
    "Здравствуйте! 🌳 Это детский сад «Домик на дереве».\n"
    "Мы принимаем детей от 2 до 6 лет.\n\n"
    "Выберите, что вас интересует:"
)

JOBS_INFO = (
    "Рады, что вы откликнулись! 🌳\n\n"
    "Сейчас ищем в команду:\n\n"
    "👩‍🏫 Воспитатель — от 60 000 ₽, 09:30–18:00\n"
    "Работа с детьми, проведение занятий, присмотр\n\n"
    "🧸 Няня — от 50 000 ₽, 08:00–16:00\n"
    "Помощь воспитателю, уборка, организация питания\n\n"
    "Для всех: бесплатное 3-разовое питание, комфортное рабочее место.\n"
    "📍 КП «Орловское», ул. Обухова, 19\n\n"
    "На какую вакансию откликаетесь?"
)

# ---------- кнопки ----------

BTN_BOOK = "📝 Записаться на экскурсию"
BTN_PRICES = "💰 Цены"
BTN_CONTACTS = "📍 Адрес и контакты"
BTN_HUMAN = "💬 Задать вопрос"
BTN_JOB = "👩‍🏫 Я по вакансии"
JOB_TEACHER = "Воспитатель"
JOB_NANNY = "Няня"
BTN_NO_EXP = "Без опыта"
BTN_CANCEL = "Отмена"
BTN_MENU = "Меню"
BTN_YES = "✅ Всё верно"
AGE_YOUNG = "2–3 года"
AGE_OLD = "3–6 лет"
TIME_OPTIONS = ["Утром (9–12)", "Днём (12–15)", "Вечером (15–18)", "Любое время"]


def kb_main():
    kb = VkKeyboard(one_time=False)
    kb.add_button(BTN_BOOK, color=VkKeyboardColor.POSITIVE)
    kb.add_line()
    kb.add_button(BTN_PRICES, color=VkKeyboardColor.SECONDARY)
    kb.add_button(BTN_CONTACTS, color=VkKeyboardColor.SECONDARY)
    kb.add_line()
    kb.add_button(BTN_HUMAN, color=VkKeyboardColor.PRIMARY)
    kb.add_line()
    kb.add_button(BTN_JOB, color=VkKeyboardColor.SECONDARY)
    return kb.get_keyboard()


def kb_options(options, cancel=True):
    kb = VkKeyboard(one_time=False)
    for i, opt in enumerate(options):
        if i and i % 2 == 0:
            kb.add_line()
        kb.add_button(opt, color=VkKeyboardColor.PRIMARY)
    if cancel:
        kb.add_line()
        kb.add_button(BTN_CANCEL, color=VkKeyboardColor.NEGATIVE)
    return kb.get_keyboard()


def kb_cancel():
    kb = VkKeyboard(one_time=False)
    kb.add_button(BTN_CANCEL, color=VkKeyboardColor.NEGATIVE)
    return kb.get_keyboard()


def kb_menu_only():
    kb = VkKeyboard(one_time=False)
    kb.add_button(BTN_MENU, color=VkKeyboardColor.SECONDARY)
    return kb.get_keyboard()

# ---------- состояние диалогов (в памяти) ----------

state = {}   # user_id -> {"step": str, "data": dict}

# ---------- работа с ВК ----------

session = vk_api.VkApi(token=TOKEN)
vk = session.get_api()


def send(user_id, text, keyboard=None):
    params = dict(peer_id=user_id, message=text, random_id=get_random_id())
    if keyboard is not None:
        params["keyboard"] = keyboard
    vk.messages.send(**params)


def user_link(user_id):
    try:
        u = vk.users.get(user_ids=user_id)[0]
        return f"{u['first_name']} {u['last_name']} — vk.com/id{user_id}"
    except Exception:
        return f"vk.com/id{user_id}"


def save_lead(user_id, d):
    new = not LEADS_FILE.exists()
    with LEADS_FILE.open("a", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        if new:
            w.writerow(["Дата заявки", "Родитель", "Телефон", "Возраст ребёнка",
                        "Удобное время", "Профиль ВК"])
        w.writerow([datetime.now().strftime("%d.%m.%Y %H:%M"), d["name"], d["phone"],
                    d["age"], d["time"], f"vk.com/id{user_id}"])


def save_job(user_id, d):
    new = not JOBS_FILE.exists()
    with JOBS_FILE.open("a", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        if new:
            w.writerow(["Дата отклика", "Вакансия", "Имя", "Телефон", "Опыт", "Профиль ВК"])
        w.writerow([datetime.now().strftime("%d.%m.%Y %H:%M"), d["job"], d["name"],
                    d["phone"], d["exp"], f"vk.com/id{user_id}"])


def notify_admins(user_id, d, text=None):
    msg = text or (
        "🔔 Новая заявка на экскурсию\n\n"
        f"Родитель: {d['name']}\n"
        f"Телефон: {d['phone']}\n"
        f"Ребёнок: {d['age']}\n"
        f"Удобное время: {d['time']}\n"
        f"ВК: {user_link(user_id)}\n\n"
        f"Переписка: vk.com/gim{GROUP_ID}?sel={user_id}"
    )
    for admin in ADMIN_IDS:
        try:
            send(admin, msg)
        except vk_api.exceptions.ApiError as e:
            print(f"Не удалось отправить заявку админу {admin}: {e}")


def normalize_phone(text):
    digits = re.sub(r"\D", "", text)
    if len(digits) == 11 and digits[0] in "78":
        digits = "7" + digits[1:]
    elif len(digits) == 10:
        digits = "7" + digits
    else:
        return None
    return f"+7 ({digits[1:4]}) {digits[4:7]}-{digits[7:9]}-{digits[9:11]}"

# ---------- логика ----------

def show_menu(uid, text=WELCOME):
    state.pop(uid, None)
    send(uid, text, kb_main())


def handle(uid, text):
    t = text.strip()
    s = state.get(uid)

    # Режим «живой администратор»: бот молчит, пока человек не нажмёт «Меню»
    if s and s["step"] == "human":
        if t == BTN_MENU:
            show_menu(uid)
        return

    if t in (BTN_CANCEL, BTN_MENU) or t.lower() in ("начать", "start", "меню"):
        show_menu(uid)
        return

    if not s:
        if t == BTN_BOOK:
            state[uid] = {"step": "age", "data": {}}
            send(uid, "Отлично! Сколько лет ребёнку?", kb_options([AGE_YOUNG, AGE_OLD]))
        elif t == BTN_PRICES:
            send(uid, PRICES, kb_main())
        elif t == BTN_CONTACTS:
            send(uid, CONTACTS, kb_main())
        elif t == BTN_JOB:
            state[uid] = {"step": "job", "data": {}}
            send(uid, JOBS_INFO, kb_options([JOB_TEACHER, JOB_NANNY]))
        elif t == BTN_HUMAN:
            state[uid] = {"step": "human", "data": {}}
            send(uid, "Напишите ваш вопрос — администратор ответит вам здесь в рабочее время.\n"
                      "Чтобы вернуться к боту, нажмите «Меню».", kb_menu_only())
            notify_admins(uid, None, f"💬 Вопрос от {user_link(uid)}\n"
                                     f"Ответить: vk.com/gim{GROUP_ID}?sel={uid}")
        else:
            show_menu(uid)
        return

    d = s["data"]
    step = s["step"]

    # ----- отклик на вакансию -----
    if step == "job":
        if t not in (JOB_TEACHER, JOB_NANNY):
            send(uid, "Пожалуйста, выберите вакансию кнопкой 👇", kb_options([JOB_TEACHER, JOB_NANNY]))
            return
        d["job"] = t
        s["step"] = "job_name"
        send(uid, "Как вас зовут? Напишите имя и фамилию.", kb_cancel())

    elif step == "job_name":
        d["name"] = t[:100]
        s["step"] = "job_phone"
        send(uid, "Оставьте номер телефона — руководитель перезвонит вам 📞", kb_cancel())

    elif step == "job_phone":
        phone = normalize_phone(t)
        if not phone:
            send(uid, "Похоже, в номере ошибка. Напишите его в формате +7 900 123-45-67", kb_cancel())
            return
        d["phone"] = phone
        s["step"] = "job_exp"
        send(uid, "Коротко расскажите об опыте работы с детьми и образовании "
                  "(или нажмите «Без опыта»).", kb_options([BTN_NO_EXP]))

    elif step == "job_exp":
        d["exp"] = t[:500]
        s["step"] = "job_confirm"
        send(uid, "Проверьте, пожалуйста:\n\n"
                  f"💼 {d['job']}\n👤 {d['name']}\n📞 {d['phone']}\n📚 {d['exp']}",
             kb_options([BTN_YES]))

    elif step == "job_confirm":
        if t != BTN_YES:
            send(uid, "Нажмите «✅ Всё верно» или «Отмена», чтобы начать заново.", kb_options([BTN_YES]))
            return
        save_job(uid, d)
        notify_admins(uid, d, "👩‍🏫 Отклик на вакансию\n\n"
                              f"Вакансия: {d['job']}\n"
                              f"Имя: {d['name']}\n"
                              f"Телефон: {d['phone']}\n"
                              f"Опыт: {d['exp']}\n"
                              f"ВК: {user_link(uid)}\n\n"
                              f"Переписка: vk.com/gim{GROUP_ID}?sel={uid}")
        show_menu(uid, "Спасибо! 🌳 Отклик принят. Руководитель свяжется с вами "
                       "в ближайшее рабочее время.")

    # ----- запись на экскурсию -----
    elif step == "age":
        if t not in (AGE_YOUNG, AGE_OLD):
            send(uid, "Пожалуйста, выберите вариант кнопкой 👇", kb_options([AGE_YOUNG, AGE_OLD]))
            return
        d["age"] = t
        s["step"] = "time"
        send(uid, "В какое время вам удобно прийти на экскурсию (пн–пт)?\n"
                  "Можно выбрать кнопкой или написать день и время.", kb_options(TIME_OPTIONS))

    elif step == "time":
        d["time"] = t
        s["step"] = "name"
        send(uid, "Как к вам обращаться?", kb_cancel())

    elif step == "name":
        d["name"] = t[:100]
        s["step"] = "phone"
        send(uid, "Оставьте номер телефона, чтобы мы подтвердили время экскурсии 📞", kb_cancel())

    elif step == "phone":
        phone = normalize_phone(t)
        if not phone:
            send(uid, "Похоже, в номере ошибка. Напишите его в формате +7 900 123-45-67", kb_cancel())
            return
        d["phone"] = phone
        s["step"] = "confirm"
        send(uid, "Проверьте, пожалуйста:\n\n"
                  f"👤 {d['name']}\n📞 {d['phone']}\n👶 {d['age']}\n🕗 {d['time']}",
             kb_options([BTN_YES]))

    elif step == "confirm":
        if t != BTN_YES:
            send(uid, "Нажмите «✅ Всё верно» или «Отмена», чтобы начать заново.", kb_options([BTN_YES]))
            return
        save_lead(uid, d)
        notify_admins(uid, d)
        show_menu(uid, "Спасибо! 🌳 Заявка принята. Мы свяжемся с вами, "
                       "чтобы подтвердить день и время экскурсии.")


def main():
    longpoll = VkBotLongPoll(session, GROUP_ID)
    print("Бот запущен. Остановить: Ctrl+C")
    for event in longpoll.listen():
        if event.type != VkBotEventType.MESSAGE_NEW:
            continue
        msg = event.obj.message
        uid = msg["from_id"]
        if msg["peer_id"] != uid:
            continue  # игнорируем беседы, отвечаем только в личных сообщениях
        text = msg.get("text", "")
        # нажатия кнопок из payload «start»
        if msg.get("payload"):
            try:
                if json.loads(msg["payload"]).get("command") == "start":
                    text = "начать"
            except (ValueError, AttributeError):
                pass
        try:
            handle(uid, text)
        except Exception as e:
            print(f"Ошибка при обработке сообщения от {uid}: {e}")


if __name__ == "__main__":
    while True:
        try:
            main()
        except KeyboardInterrupt:
            break
        except vk_api.exceptions.ApiError as e:
            if e.code in (5, 15, 27, 100):
                print(f"\nОшибка ВК: {e}\n"
                      "Проверьте в группе: Управление → Работа с API →\n"
                      " • Long Poll API: «Включено», тип события «Входящее сообщение»;\n"
                      " • ключ доступа с правами «управление сообществом» и «сообщения сообщества».\n"
                      "После исправления запустите бота снова.")
                if sys.stdin and sys.stdin.isatty():
                    input("Нажмите Enter, чтобы закрыть...")
                break
            print(f"Переподключение после ошибки: {e}")
            time.sleep(5)
        except Exception as e:  # обрыв связи — переподключаемся
            print(f"Переподключение после ошибки: {e}")
            time.sleep(5)
BOTEOF
python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q vk_api

echo
read -rsp "Вставьте КЛЮЧ ДОСТУПА группы (символы не отображаются) и нажмите Enter: " TOKEN; echo
read -rp "Короткие адреса админов для уведомлений через пробел [zhivi_po_lubvi]: " ADMINS
ADMINS=${ADMINS:-zhivi_po_lubvi}

ADMIN_IDS=$(TOKEN="$TOKEN" ADMINS="$ADMINS" ./venv/bin/python - <<'PYEOF'
import os, vk_api
api = vk_api.VkApi(token=os.environ["TOKEN"]).get_api()
ids = []
for a in os.environ["ADMINS"].replace(",", " ").split():
    a = a.strip().split("/")[-1]
    if a.isdigit():
        ids.append(a); continue
    if a.startswith("id") and a[2:].isdigit():
        ids.append(a[2:]); continue
    try:
        r = api.utils.resolveScreenName(screen_name=a)
        if r and r.get("type") == "user":
            ids.append(str(r["object_id"]))
    except Exception as e:
        import sys; print("не удалось найти", a, e, file=sys.stderr)
print(",".join(ids))
PYEOF
)
echo "ID админов: ${ADMIN_IDS:-(не найдены)}"

cat > .env <<ENVEOF
VK_GROUP_TOKEN=$TOKEN
VK_GROUP_ID=190471109
VK_ADMIN_IDS=$ADMIN_IDS
ENVEOF
chmod 600 .env

cat > /etc/systemd/system/domikbot.service <<'SVCEOF'
[Unit]
Description=VK bot Domik na dereve
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/domikbot
ExecStart=/opt/domikbot/venv/bin/python -u /opt/domikbot/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable --now domikbot
sleep 4
journalctl -u domikbot -n 8 --no-pager
echo
echo "=== Готово. Напишите «Меню» в сообщения группы. ==="
