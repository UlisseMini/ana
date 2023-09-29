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
from typing import List, Optional

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
    message = Message(role='', content='')
    async with openai.stream(
        method='POST',
        url="/v1/chat/completions",
        json={**body, "stream": True},
    ) as resp:
        resp.raise_for_status()
        # chunks are "data: {json}\n\n"
        async for chunk in resp.aiter_lines():
            if not chunk.startswith("data: "):
                continue
            data_str = chunk.split("data: ")[1].strip()
            resp_json = json.loads(data_str)
            choice = resp_json['choices'][0]

            if choice['finish_reason'] or choice.get('delta') is None:
                break

            message.content += resp_json['choices'][0]['delta'].get('content', '')
            message.role = resp_json['choices'][0]['delta'].get('role', message.role)

            yield message


# Pydantic models for app state

class Message(BaseModel):
    role: str
    content: str

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

                # FIXME: Weird bug where new msg isn't included. probably a race condition.
                # I need to track dates inside the app state & db.

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

                if self.app_state.messages and self.app_state.messages[-1].role == 'user':
                    await self.handle_msg()


    async def check_in(self):
        self.last_check_in = time.time()
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


    async def handle_msg(self):
        msg = self.app_state.messages[-1].content
        print(f'handling {msg}')
        # TODO: Document msgs automatically for the user
        cmds = ['/clear', '/checkin', '/activity']
        if msg in cmds:
            self.app_state.messages.pop()
            if msg == '/clear':
                self.app_state.messages = []
                await self.send_state()
                self.save_state()
            elif msg == '/checkin':
                await self.check_in()
            elif msg == '/activity':
                await self.debug(self.get_activity_text())
            await self.send_state()
        else:
            await self.respond_to_msg()

    def get_activity_text(self, prefix="The user's current visible windows are:\n- ") -> str:
        activity = '\n- '.join([
            w['kCGWindowOwnerName'] + ' - ' + w['kCGWindowName'] for w in
            self.app_state.activity.visible_windows
        ])
        return prefix + activity


    def dump_filtered_messages(self, roles=('user', 'assistant')):
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
        if message:
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
