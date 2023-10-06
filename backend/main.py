from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
import sqlite3
import os
import json
import httpx
import time
import asyncio
import re
from pydantic import BaseModel, ValidationError, Field
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Tuple

# run source ../.env to get path variables
from dotenv import load_dotenv
load_dotenv('../.env')


OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
HOST = os.environ["HOST"]


SYSTEM_PROMPT = """
You are a friendly assistant who responds with short 20 word texts. You write in a friendly, informal texting style as you would to a friend.
""".strip()

# TODO: Should be a default configurable by the users?
CHECK_IN_PROMPT = f"""
AUTOMATED MESSAGE: {{response}}
""".strip()


# TODO: Add reason?
TRIGGER_PROMPT = """
AUTOMATED MESSAGE: A user activity report is given below. Interrupt the user if the activity matches a rule the user gave for interrupting them. Otherwise call the function passing 'false'.

{activity}
""".strip()


ON_TRIGGER_MESSAGE = """
AUTOMATED MESSAGE: The user has been interrupted because their activity matched a rule they gave for interrupting them. Send a short text asking the user what they're doing and why.

{activity}
""".strip()


INITIAL_MESSAGE = """
Nice to meet you! I'm BossGPT, your friendly assistant who helps you stay focused.

When should I check in with you? For example, "When I'm on youtube for more than 10 minutes before 5pm"
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
    def model_dump(self, **kwargs):
        return super().model_dump(exclude_none=True, **kwargs)

class PromptPair(BaseModel):
    trigger: str
    response: str

class Settings(BaseModel):
    prompts: List[PromptPair]
    check_in_interval: int = Field(..., alias='checkInInterval')


Window = dict

class Activity(BaseModel):
    visible_windows: List[Window] = Field(..., alias='visibleWindows')


class AppState(BaseModel):
    machine_id: str = Field(..., alias='machineId')
    username: str
    messages: List[Message]
    settings: Settings
    activity: Activity



def get_activity_times(db, start: datetime, end: datetime):
    cur = db.cursor()
    query = '''
    SELECT json_extract(state_json, '$.activity'), created_at
    FROM app_states WHERE created_at BETWEEN ? and ? ORDER BY created_at ASC
    '''
    cur.execute(query, (start.strftime('%Y-%m-%d %H:%M:%S'), end.strftime('%Y-%m-%d %H:%M:%S')))

    rows = cur.fetchall()
    activity = [Activity.model_validate_json(a) for a, _ in rows]
    times = [datetime.strptime(t, '%Y-%m-%d %H:%M:%S') for _, t in rows]
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
def get_activity_summary_from_db(db, start: datetime, end: datetime) -> str:
    app_time, title_time = get_activity_times(db, start, end)
    return get_activity_summary_from_times(app_time, title_time, start, end)



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
        self.last_check_in = 0

        # for fast-forward: a (time, activity_summary) pair
        self.fastfwd: Optional[Tuple[datetime, str]] = None

        # TODO: Ensure no two clients from the same computer can connect at once.


    async def run(self):
        await self.ws.accept()

        while True:
            msg = await self.receive(timeout=10)
            if not msg:
                time_since_check_in = time.time() - self.last_check_in
                if time_since_check_in > self.app_state.settings.check_in_interval:
                    await self.check_in()

                continue

            if msg['type'] == 'state':
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
                    self.app_state.messages.append(Message(role='assistant', content=INITIAL_MESSAGE))
                    await self.send_state()


                # handle messages
                if self.app_state.messages and self.app_state.messages[-1].role == 'user':
                    await self.handle_msg()


    async def get_activity_summary(self, start: datetime, end: datetime) -> str:
        if self.fastfwd and start <= self.fastfwd[0] <= end:
            print(f'fast forwarding: fastfwd at {self.fastfwd[1]}')
            return self.fastfwd[1]

        return get_activity_summary_from_db(self.db, start, end)


    async def trigger_message(self) -> Optional[Message]:
        """
        If we should trigger, return the trigger message. Otherwise, return None.
        """

        last_n_seconds = self.app_state.settings.check_in_interval
        now = datetime.now(tz=timezone.utc).replace(tzinfo=None)
        activity = await self.get_activity_summary(now - timedelta(seconds=last_n_seconds), now)
        if len(activity.strip().split('\n')) == 1:
            await self.debug("Not enough activity recorded to trigger yet")
            return None

        activity_msg = Message(role='user', content=TRIGGER_PROMPT.format(activity=activity))
        await self.debug(f"Trigger msg:\n{activity_msg.content}")

        resp = await openai.post(
            "/v1/chat/completions",
            json={
                "model": "gpt-4",
                "messages": self.dump_filtered_messages() + [activity_msg.model_dump()],
                "functions": [{
                    # this should be either True or False, always called.
                    "name": "trigger",
                    "description": "Pass true to interrupt the user, or false not to",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "trigger": {
                                "type": "boolean"
                            }
                        },
                        "required": ["trigger"],
                    },
                }],
                "max_tokens": 100,
                "temperature": 0,
            }
        )
        resp.raise_for_status()
        resp_data = resp.json()
        message = resp_data['choices'][0]['message']
        trigger = False
        if message.get("function_call") and message["function_call"]["name"] == 'trigger':
            try:
                trigger = json.loads(message["function_call"]["arguments"])["trigger"]
            except json.JSONDecodeError:
                pass
        else:
            await self.debug(f"no trigger call in response:\n{message}")

        if trigger:
            return Message(role='user', content=ON_TRIGGER_MESSAGE.format(activity=activity))


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
        message = await self.trigger_message()
        if message:
            self.app_state.messages.append(message)
            await self.respond_to_msg()


    async def handle_msg(self):
        msg = self.app_state.messages[-1].content
        print(f'handling {msg}')
        # TODO: Document msgs automatically for the user
        cmds = ['/clear', '/checkin', '/activity', '/fastfwd']
        if msg in cmds:
            self.app_state.messages.pop()
            if msg == '/clear':
                args = msg.split(' ')
                try:
                    self.app_state.messages = self.app_state.messages[:-int(args[1])]
                except (IndexError, ValueError):
                    self.app_state.messages = []
                await self.send_state()
                self.save_state()
            elif msg == '/checkin':
                await self.check_in()
            elif msg == '/activity':
                await self.debug(self.get_activity_text())
            elif msg == '/fastfwd':
                await self.fast_forward()
                await self.check_in()

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
        start = datetime.now(tz=timezone.utc).replace(tzinfo=None)
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


    def dump_filtered_messages(self, roles=('user', 'assistant', 'function')):
        "Dump messages for the OpenAI API"
        return [m.model_dump() for m in self.app_state.messages if m.role in roles]


    async def respond_to_msg(self):
        "Respond to the most recent user message in app_state.messages"

        # prepend system prompt
        sys_prompt = SYSTEM_PROMPT
        if self.app_state.messages[0].role == 'system':
            self.app_state.messages[0].content = sys_prompt
        else:
            self.app_state.messages.insert(0, Message(role='system', content=sys_prompt))


        message = None
        async for message in stream_completion({
            # 3.5 wasn't able to follow the extremely hard instruction of "send short messages"
            "model": "gpt-4",
            "messages": self.dump_filtered_messages(),
            "max_tokens": 1000, # will use much less
        }):
            if self.app_state.messages[-1] is not message:
                self.app_state.messages.append(message)

            await self.send_state()
        if message and message.content:
            await self.notify(title="BossGPT", body=message.content)
        self.save_state()


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
