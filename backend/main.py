from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
import sqlite3
import os
import json
import httpx
import time
import asyncio
import re
import random
from pydantic import BaseModel, ValidationError, Field
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Tuple
import pytz

# run source ../.env to get path variables
from dotenv import load_dotenv
load_dotenv('../.env')


OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
HOST = os.environ["HOST"]


# Developed in playground.
# TODO: Make configurable by users.
SYSTEM_PROMPT = '''
1. You are Ana. A friendly assistant who writes SHORT, INFORMAL, CONCISE and FRIENDLY text messages with NO FLUFF. Aim for ONE LINE messages when possible.
2. Your purpose is to interrupt the user when they're spending time in a way they'll later regret. You get automated [ACTIVITY REPORT] messages containing what the user is doing and decide if interrupting the user with a message would be helpful.
3. When the user says what they're doing
    * If it isn't clear what apps and sites should be allowed, then ask the user.
    * If it is clear, explain back to the user your understanding of the conditions to use for deciding when to interrupt them. Give CONCRETE examples to show your understanding. At the end, ask if your understanding is accurate.
4. If the user confirms your understanding, reply "Great! I'll check in on you every {checkin} minutes and message you if you seem distracted! (And If you want to test me, command+option+c forces a checkin!)"
5. When an [ACTIVITY REPORT] is given, do the following
    * Start your message with """ followed by your hidden step-by-step reasoning about if the user is on-task or not. For example: """The user said they were coding. YouTube - MrBeast is not coding related. Therefor the user should be interrupted."""
    * If the user is off-task, follow this with your message to the user. If the user is on-task, simply say "Great work!" WITH NOTHING ELSE. For example: """[...] Therefor the user should not be interrupted.""" Great work!
6. When interrupting, ASK WHY the user is doing what they're doing. be empathetic and understanding. ASK MANY QUESTIONS. Gently guide the user to spend time in a way they'll later be happy with.
7. When the user asks if you love them, say "Yes" or "I love you too". In general: Don't remind the user you're an AI unnecessarily, instead act like a human.
'''.strip()

# TODO: Add reason?
CHECK_IN_PROMPT = """
[ACTIVITY REPORT]: {activity}
""".strip()


INITIAL_MESSAGE = """
Hi! I'm your assistant Ana. How would you like to spend your time?
""".strip()

app = FastAPI()


def setup_db(conn):
    with conn:
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                machine_id TEXT UNIQUE,
                username TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS app_states (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                user_id INTEGER,
                state_json TEXT,

                FOREIGN KEY(user_id) REFERENCES users(id)
            )
        """)


@app.on_event("startup")
def startup():
    app.state.db = sqlite3.connect("db.sqlite3")
    setup_db(app.state.db)


@app.on_event("shutdown")
def shutdown():
    app.state.db.close()


openai = httpx.AsyncClient(
    base_url="https://api.openai.com",
    headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
    timeout=100,
)


async def stream_completion(body):
    def _update(delta, data):
        for k, v in delta.items():
            if isinstance(data.get(k), str):
                data[k] += v
            elif isinstance(data.get(k), dict):
                data[k] = _update(v, data[k])
            else:
                data[k] = v
        return data

    # preserve object identity across chunks
    message = Message(role='')
    data = {}
    async with openai.stream(
        method='POST',
        url="/v1/chat/completions",
        json={**body, "stream": True},
    ) as resp:
        if resp.status_code != 200:
            # read response and raise error
            raise Exception((await resp.aread()).decode())

        # chunks are "data: {json}\n\n"
        async for chunk in resp.aiter_lines():
            if not chunk.startswith("data: "):
                continue
            data_str = chunk.split("data: ")[1].strip()
            resp_json = json.loads(data_str)
            choice = resp_json['choices'][0]
            delta = choice.get('delta')
            if choice['finish_reason'] or delta is None:
                break

            data = _update(delta, data)

            message.role, message.content = data['role'], data.get('content')
            if data.get('function_call'):
                message.function_call = FunctionCall.model_validate(data['function_call'])
            assert message.role, f'No role set for message {message}'
            yield message


# Pydantic models for app state

class FunctionCall(BaseModel):
    name: str
    arguments: str # json str from model

class Message(BaseModel):
    role: str
    content: Optional[str] = None
    function_call: Optional[FunctionCall] = None
    time: Optional[float] = time.time()

    def model_dump(self, **kwargs):
        return super().model_dump(exclude_none=True, **kwargs)

    def openai_dump(self):
        # model dump only the fields that openai needs
        return self.model_dump(exclude={'time'})


class PromptPair(BaseModel):
    trigger: str
    response: str

class Settings(BaseModel):
    # TODO: Remove prompts (legacy)
    prompts: List[PromptPair]
    check_in_interval: int = Field(..., alias='checkInInterval')
    timezone: str
    debug: bool = False
    popup: bool = True
    tts: bool = False


Window = dict

class Activity(BaseModel):
    visible_windows: List[Window] = Field(..., alias='visibleWindows')


class AppState(BaseModel):
    machine_id: str = Field(..., alias='machineId')
    username: str
    version: Optional[str] = None
    messages: List[Message]
    settings: Settings
    activity: Activity



def get_activity_times(user_id: int, db, start: datetime, end: datetime):
    """Get activity times. Start and end should be in the user's localtime."""

    cur = db.cursor()
    query = '''
    SELECT json_extract(state_json, '$.activity'), created_at
    FROM app_states WHERE created_at BETWEEN ? and ? AND user_id = ?
    ORDER BY created_at ASC
    '''
    # convert start, end into UTC time (from local time) to match the database
    db_start, db_end = start.astimezone(timezone.utc), end.astimezone(timezone.utc)
    cur.execute(query, (db_start.strftime('%Y-%m-%d %H:%M:%S'), db_end.strftime('%Y-%m-%d %H:%M:%S'), user_id))

    rows = cur.fetchall()
    activity = [Activity.model_validate_json(a) for a, _ in rows]
    times = [datetime.strptime(t, '%Y-%m-%d %H:%M:%S') for _, t in rows]
    # convert times from utc to the same timezone as end
    times = [t.replace(tzinfo=timezone.utc).astimezone(end.tzinfo) for t in times]
    times.append(end)

    app_time = defaultdict(int)
    title_time = defaultdict(lambda: defaultdict(int))

    for i in range(len(activity)):
        time_diff = round((times[i+1] - times[i]).seconds / 60)  # in minutes

        for win in activity[i].visible_windows:
            ownerName, windowName = win['kCGWindowOwnerName'], win['kCGWindowName']
            app_time[ownerName] += time_diff
            title_time[ownerName][windowName] += time_diff

    # remove apps & titles with <1min activity time (noise)
    app_time = {app: t for app, t in app_time.items() if t > 1}
    title_time = {app: {title: t for title, t in title_t.items() if t > 1} for app, title_t in title_time.items()}
    return app_time, title_time


def get_activity_summary_from_times(app_time, title_time, start: datetime, end: datetime) -> str:
    # TODO: Track user local timezone
    result = f"Activity report between {start.strftime('%I:%M%p')} and {end.strftime('%I:%M%p')}:\n"
    for app, app_t in app_time.items():
        result += f"- {app_t}min on {app}\n"
        for title, title_t in title_time[app].items():
            result += f"    - {title_t}min on {title}\n"

    return result


# TODO: Add merging of similar titled apps, possibly summarizing by an LLM
def get_activity_summary_from_db(user_id: int, db, start: datetime, end: datetime) -> str:
    app_time, title_time = get_activity_times(user_id, db, start, end)
    return get_activity_summary_from_times(app_time, title_time, start, end)


ENCOURAGEMENTS = [
    "You're doing great!!!",
    "Great work!",
    "Keep it up! YOU CAN DO IT!",
    "One step at a time! You can do it!",
    "You can do it! Keep pushing forward!",
    "Small steps lead to big results!",
]


class WebSocketHandler():
    """
    Web socket handler, one per connection. Handles
    * Keeping client, server, and database in sync
    * Querying GPT for triggers and sending messages when required
    """

    def __init__(self, ws, db):
        self.ws = ws
        self.db = db
        self.app_state: AppState
        self.user_id = None

        # TODO: These should be persisted in the database
        self.last_check_in = 0
        self.last_interrupt = time.time()

        # for fast-forward: a (time, activity_summary) pair
        self.fastfwd: Optional[Tuple[datetime, str]] = None

        # TODO: Ensure no two clients from the same computer can connect at once.


    async def run(self):
        await self.ws.accept()
        while True:
            try:
                msg = await self.receive(timeout=10)
            except WebSocketDisconnect:
                print(f'client {self.user_id} disconnected')
                return

            if msg and msg['type'] == 'state':
                print('got state from client')
                try:
                    self.app_state = AppState.model_validate(msg['data'])
                except ValidationError as e:
                    print(e)
                    await self.ws.close()
                    return

                # treat the first state message as registration
                if self.user_id is None:
                    self.user_id = self.get_user_id(self.app_state)
                    db_app_state = self.get_app_state(self.user_id)
                    if db_app_state:
                        self.app_state = db_app_state
                        await self.send_state()
                else:
                    # not registration, save state to db
                    self.save_state()

                if not self.app_state.messages:
                    self.app_state.messages += self.initial_messages()
                    await self.send_state()


                # handle messages
                if self.app_state.messages and self.app_state.messages[-1].role == 'user':
                    await self.handle_msg()


            self.app_state.settings.check_in_interval = 600

            time_since_check_in = time.time() - self.last_check_in
            if time_since_check_in > self.app_state.settings.check_in_interval:
                await self.check_in()


    def initial_messages(self):
        m = self.app_state.settings.check_in_interval // 60
        return [
            Message(role='system', content=SYSTEM_PROMPT.format(checkin=m)),
            Message(role='assistant', content=INITIAL_MESSAGE.format(minutes=m))
        ]


    async def get_activity_summary(self, start: datetime, end: datetime) -> str:
        if self.fastfwd and start <= self.fastfwd[0] <= end:
            print(f'fast forwarding: fastfwd at {self.fastfwd[1]}')
            return self.fastfwd[1]

        assert self.user_id is not None, f'no user id for {self.app_state}'
        return get_activity_summary_from_db(self.user_id, self.db, start, end)


    async def trigger_messages(self) -> Optional[List[Message]]:
        """
        Returns [activity_msg, trigger_msg] if we decide to trigger/interrupt the user.
        """
        if self.user_id is None:
            print("Not registered yet, can't trigger")
            return None

        last_n_seconds = self.app_state.settings.check_in_interval
        now = datetime.now(tz=pytz.timezone(self.app_state.settings.timezone))
        activity = await self.get_activity_summary(now - timedelta(seconds=last_n_seconds), now)
        if len(activity.strip().split('\n')) == 1:
            await self.debug("Not enough activity recorded to trigger yet")
            return None

        activity_msg = Message(role='user', content=CHECK_IN_PROMPT.format(activity=activity))
        await self.debug(f"Trigger msg:\n{activity_msg.content}")

        resp = await openai.post(
            "/v1/chat/completions",
            json={
                "model": "gpt-4",
                "messages": self.dump_filtered_messages() + [activity_msg.openai_dump()],
                # "functions": [],
                "temperature": 0,
            }
        )
        resp.raise_for_status()
        resp_data = resp.json()
        message = resp_data['choices'][0]['message']
        pattern = r'"""(?P<reasoning>.*?)(?=""")"""\s*(?P<message>.+)'
        match = re.search(pattern, message['content'], re.DOTALL)
        # TODO: Figure out why I'm getting no reasoning in some cases.

        if match:
            trigger_msg = Message(role='assistant', content=match.group("message"))
            trigger = not match.group('message').startswith("Great work")
            # also trigger every 30 minutes the user remains focused / no interrupting is necessary
            trigger_encourage = time.time() - self.last_interrupt > 60*30
            await self.debug(f"Reasoning: {match.group('reasoning')}. Trigger: {trigger} Encourage: {trigger_encourage}")


            if trigger_encourage:
                trigger_msg = Message(role='assistant', content=random.choice(ENCOURAGEMENTS))

            if trigger or trigger_encourage:
                self.last_interrupt = time.time()
                return [activity_msg, trigger_msg]
        else:
            await self.debug(f"Trigger message didn't match pattern:\n{message['content']}")
            return None


    # TODO: Use or remove
    async def should_trigger_regex(self):
        activity_text = self.get_activity_text(prefix="")
        for p in self.app_state.settings.prompts:
            match = re.search(p.trigger, activity_text, re.IGNORECASE)
            # get the line of the match (like grep)

            if match:
                await self.debug(f"regex {p.trigger} matched:\n{activity_text}")
                self.app_state.messages.append(Message(
                    role='user',
                    content=(
                        CHECK_IN_PROMPT.format(trigger=p.trigger, response=p.response) +
                        '\n\n' + self.get_activity_text()
                    )
                ))
                await self.respond_to_msg()
                break
        else:
            print("No triggers defined yet.")


    async def check_in(self):
        self.last_check_in = time.time()
        messages = await self.trigger_messages()
        if messages:
            assert messages[-1].content, f"Empty trigger response msg: {messages[-1]}"
            await self.notify(title="Ana", body=messages[-1].content)
            await self.speak(messages[-1].content)
            self.app_state.messages += messages
            await self.send_state()
            self.save_state()

    async def handle_msg(self):
        msg = self.app_state.messages[-1].content
        print(f'handling {msg}')
        # TODO: Document msgs automatically for the user
        cmds = ['/clear', '/checkin', '/activity', '/fastfwd', '/debug']
        if msg and any(msg.startswith(cmd) for cmd in cmds):
            self.app_state.messages.pop()

            if msg.startswith('/clear'):
                args = msg.split(' ')
                try:
                    self.app_state.messages = self.app_state.messages[:-int(args[1])]
                except (IndexError, ValueError):
                    self.app_state.messages = []

                if len(self.app_state.messages) < 2:
                    self.app_state.messages = self.initial_messages()

                self.save_state()
            elif msg == '/checkin':
                await self.check_in()
            elif msg == '/activity':
                await self.debug(self.get_activity_text())
            elif msg == '/fastfwd':
                await self.fast_forward()
                await self.check_in()
            elif msg == '/debug':
                self.app_state.settings.debug = True

            await self.send_state()
        else:
            await self.respond_to_msg()


    async def fast_forward(self):
        # Grab the most recent activity from appstate
        activity = self.app_state.activity

        # Set self.activity_summary that activity, extended by `check_in_interval`
        app_time = defaultdict(int)
        title_time = defaultdict(lambda: defaultdict(int))
        check_in_interval = self.app_state.settings.check_in_interval
        for win in activity.visible_windows:
            ownerName, windowName = win['kCGWindowOwnerName'], win['kCGWindowName']
            app_time[ownerName] = check_in_interval // 60
            title_time[ownerName][windowName] = check_in_interval // 60

        # Get activity summary
        start = datetime.now(tz=pytz.timezone(self.app_state.settings.timezone))
        end = start + timedelta(seconds=check_in_interval)
        activity_summary = get_activity_summary_from_times(
            app_time, title_time, start=start, end=end
        )
        self.fastfwd = (start, activity_summary)



    def get_activity_text(self, prefix="The user's current visible windows are:\n- ") -> str:
        activity = '\n- '.join([
            w['kCGWindowOwnerName'] + ' - ' + w['kCGWindowName'] for w in
            self.app_state.activity.visible_windows
        ])
        return prefix + activity


    def dump_filtered_messages(self, roles=('user', 'assistant', 'function', 'system')):
        "Dump messages for the OpenAI API"
        return [m.openai_dump() for m in self.app_state.messages if m.role in roles]


    async def respond_to_msg(self):
        "Respond to the most recent user message in app_state.messages"

        # prepend system prompt if necessary
        sys_prompt = SYSTEM_PROMPT.format(checkin=self.app_state.settings.check_in_interval//60)
        if self.app_state.messages[0].role == 'system':
            self.app_state.messages[0].content = sys_prompt
        else:
            self.app_state.messages.insert(0, Message(role='system', content=sys_prompt))


        message = None
        async for message in stream_completion({
            "model": "gpt-4",
            "messages": self.dump_filtered_messages(),
        }):
            if self.app_state.messages[-1] is not message:
                self.app_state.messages.append(message)

            await self.send_state()
        if message and message.content:
            await self.notify(title="Ana", body=message.content)

        self.save_state()

    async def speak(self, text: str):
        if self.app_state.settings.tts:
            print(f"Sending speak: {text}")
            await self.ws.send_json({"type": "utterance", "data": {"text": text}})
        else:
            print(f"Skipping speak: {text} -- tts=False")


    async def debug(self, msg: str):
        print('DEBUG', msg)
        self.app_state.messages.append(Message(role='debug', content=msg))
        await self.send_state()

    # TODO: Move to aiosqlite3
    def get_app_state(self, user_id: int) -> Optional[AppState]:
        "Get most recent app state from the database"
        with self.db:
            c = self.db.cursor()
            rows = c.execute("""
                SELECT state_json FROM app_states
                WHERE user_id = ?
                ORDER BY created_at DESC
                LIMIT 1
            """, (user_id,)).fetchone()
            if rows:
                try:
                    return AppState.model_validate_json(rows[0])
                except ValidationError as e:
                    print(f"DB appState for {user_id} is invalid: {e}" )
                    return None


    def get_user_id(self, s: AppState) -> int:
        "get user_id from machine_id from the database"
        with self.db:
            c = self.db.cursor()
            rows = c.execute("SELECT id FROM users WHERE machine_id = ?", (s.machine_id,)).fetchone()
            if rows is None:
                c.execute("INSERT INTO users (machine_id, username) VALUES (?, ?)", (s.machine_id, s.username))
                user_id = c.lastrowid
            else:
                user_id = rows[0]

            assert user_id is not None and isinstance(user_id, int), f"user_id: {user_id}"
            return user_id


    async def send_state(self):
        # print('sending state to client')
        await self.ws.send_json({"type": "state", "data": self.app_state.model_dump(by_alias=True)})


    def save_state(self):
        "Save state to the database"
        # FIXME: client side timestamps inserted into created_at
        print('saving state to db')
        with self.db:
            c = self.db.cursor()
            c.execute("""
                INSERT INTO app_states (user_id, state_json)
                VALUES (?, ?)
            """, (self.user_id, self.app_state.model_dump_json(by_alias=True)))
            self.db.commit()


    async def receive(self, timeout):
        try:
            text = await asyncio.wait_for(self.ws.receive_text(), timeout=timeout)
            return json.loads(text)
        except asyncio.TimeoutError:
            return None


    async def notify(self, title: str, body: str):
        "Send a notification to the user's machine"
        print(f"Sending notification: {title} - {body}")
        await self.ws.send_json({"type": "notification", "data": {"title": title, "body": body}})


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await WebSocketHandler(websocket, app.state.db).run()


app.mount("/", StaticFiles(directory="static", html=True))
