from fastapi import FastAPI, WebSocket
from fastapi.staticfiles import StaticFiles
import sqlite3
import os
import json
import httpx
import asyncio
from pydantic import BaseModel, ValidationError
from typing import List, Optional

# run source ../.env to get path variables
from dotenv import load_dotenv
load_dotenv('../.env')


OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
HOST = os.environ["HOST"]

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


client = httpx.AsyncClient(
    base_url="https://api.openai.com",
    headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
    timeout=100,
)


# Pydantic models for app state

class Message(BaseModel):
    role: str
    content: str

class PromptPair(BaseModel):
    trigger: str
    response: str

class Settings(BaseModel):
    prompts: List[PromptPair]
    check_in_interval: int

class AppState(BaseModel):
    machine_id: str
    username: str
    messages: List[Message]
    settings: Settings


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

        # TODO: Ensure no two clients from the same computer can connect at once.


    async def run(self):
        await self.ws.accept()

        while True:
            msg = await self.receive(timeout=10)
            if not msg:
                continue # later we'll do stuff here

            if msg['type'] == 'state':
                print('got state from client')
                try:
                    self.app_state = AppState.model_validate(msg['state'])
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

                if self.app_state.messages and self.app_state.messages[-1].role != 'assistant':
                    print(f'responding to {self.app_state.messages[-1].content}')
                    await self.respond_to_msg()


    async def respond_to_msg(self):
        sys_prompt = "You are a helpful assistant who responds with concise and helpful ~20 word texts. You ask questions before proposing things, both to make sure you understand and make the user feel understood."
        messages = [{'role': 'system', 'content': sys_prompt}]
        messages += [m.model_dump() for m in self.app_state.messages]

        message = Message(role='assistant', content='')
        self.app_state.messages.append(message)
        async with client.stream(
            method='POST',
            url="/v1/chat/completions",
            json={
                "model": "gpt-3.5-turbo",
                "messages": messages,
                "max_tokens": 200,
                "stream": True
            },
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

                message.content += resp_json['choices'][0]['delta']['content']
                await self.send_state()

            self.save_state()


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
        print('sending state to client')
        await self.ws.send_json({"type": "state", "state": self.app_state.model_dump()})


    def save_state(self):
        "Save state to the database"
        print('saving state to db')
        with self.db:
            c = self.db.cursor()
            c.execute("""
                INSERT INTO app_states (user_id, state_json)
                VALUES (?, ?)
            """, (self.user_id, json.dumps(self.app_state.model_dump())))
            self.db.commit()


    async def receive(self, timeout):
        try:
            text = await asyncio.wait_for(self.ws.receive_text(), timeout=timeout)
            return json.loads(text)
        except asyncio.TimeoutError:
            return None


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await WebSocketHandler(websocket, app.state.db).run()


app.mount("/", StaticFiles(directory="static", html=True))
