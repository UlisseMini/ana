from fastapi import FastAPI, Form, Request, HTTPException, WebSocket
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse
import sqlite3
import stripe
import os
import json
import httpx
import time
import random
import asyncio

# run source ../.env to get path variables
from dotenv import load_dotenv
load_dotenv('../.env')


OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
stripe.api_key = os.environ["STRIPE_API_KEY"]
HOST = os.environ["HOST"]

app = FastAPI()



def setup_db(conn):
    with conn:
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                username TEXT,
                fullname TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                -- the user the message is associated with. linked to users.id via foreign key
                user_id INTEGER,

                -- the message, in openai format. if role == "user", then this is the user's message,
                -- if role == "assistant" then this is the assistant's response to a previous message.
                role TEXT,
                content TEXT,

                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS activity (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                user_id INTEGER,

                app TEXT,
                window_title TEXT,
                time INTEGER, -- epoch time, from swift
                -- TODO add more fields for tracking activity

                FOREIGN KEY (user_id) REFERENCES users(id)
            );
        """)


@app.on_event("startup")
def startup():
    # setup db
    app.state.db = sqlite3.connect("db.sqlite3")
    setup_db(app.state.db)


@app.on_event("shutdown")
def shutdown():
    app.state.db.close()


@app.post("/create-checkout-session")
def create_checkout_session(lookup_key: str = Form(...)):
    try:
        print(lookup_key)
        prices = stripe.Price.list(
            lookup_keys=[lookup_key],
            expand=["data.product"]
        )
        print(prices)
        checkout_session = stripe.checkout.Session.create(
            line_items=[
                {
                    "price": prices.data[0].id,
                    "quantity": 1,
                }
            ],
            mode='subscription',
            success_url=f"{HOST}/success.html?session_id={{CHECKOUT_SESSION_ID}}",
            cancel_url=f"{HOST}/cancel.html",
        )
        return RedirectResponse(url=checkout_session.url, status_code=303)
    except Exception as e:
        print(e)
        raise HTTPException(status_code=500)



@app.post("/create-portal-session")
def create_portal_session(session_id: str = Form(...)):
    try:
        checkout_session = stripe.checkout.Session.retrieve(session_id)
        portalSession = stripe.billing_portal.Session.create(
            customer=checkout_session.customer,
            return_url=HOST,
        )
        return RedirectResponse(url=portalSession.url, status_code=303)
    except Exception as e:
        print(e)
        raise HTTPException(status_code=500)



@app.post("/webhook")
async def webhook_received(request: Request):
    webhook_secret = 'whsec_12345'
    request_data = await request.json()
    body = await request.body()

    if webhook_secret:
        signature = request.headers.get('stripe-signature')
        if not signature:
            return HTTPException(status_code=400, detail="Missing stripe-signature header")

        try:
            event = stripe.Webhook.construct_event(
                payload=body, sig_header=signature, secret=webhook_secret)
            data = event['data']
        except Exception as e:
            return e

        event_type = event['type']
    else:
        data = request_data['data']
        event_type = request_data['type']

    print('stripe event ' + event_type)

    # Handle different event types here
    # FIXME: Not handling these is literally illegal (impossible to unsubscribe)
    raise HTTPException(status_code=500, detail="Server error: Not implemented")

    return {"status": "success"}




@app.get("/chat")
def chat(user_id: int):
    "base level route, a direct proxy to the openai api"
    pass


@app.get("/activity")
def activity():
    "user activity tracking. stored in the db so the AI can learn"
    return "Not implemented"


SYSTEM_PROMPT = """
You are a productivity assistant who only interrupts if a user is definitely distracted from their task (e.g. on social media). If they are definitely distracted, kindly try and motivate them to work. Otherwise, affirm on-task activity with "Great work!" and nothing else. Adapt when the user updates their preferences.

After the user specifies their goal, encourage them and tell them how often you'll be checking in on them, and ask if they want to change how frequently you check in.
""".strip()

INITIAL_MESSAGE = """
Hi there! what do you want to work on right now? I can help you stay on task and be more productive!
""".strip()


client = httpx.AsyncClient(headers={"Authorization": f"Bearer {OPENAI_API_KEY}"}, timeout=100)


# TODO: Make more sophisticated. exists to avoid ctx length errors
# and to avoid repetition 
def distill_history(messages):
    # keep [sys, initial, preferences] and last 3 checkins (activity, assistant) assuming no user response.
    return messages[:3] + messages[-6:] if len(messages) > 9 else messages


# TODO: Move all this websocket logic to a class so I can use methods
# instead of repeating the same logic all over the place.
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    # TODO: These should all be stored in the database
    activity = [] # [{"type": "activity", "app": "ITerm", "window_title": "zsh", "time": <EPOCH>}]
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    check_in_every = 300
    def change_checkin(new_interval):
        if new_interval < 30:
            return {"role": "assistant", "content": "Sorry, I can't check in that often or Uli will go bankrupt. Please select a longer interval."}

        nonlocal check_in_every
        check_in_every = new_interval
        return {"role": "assistant", "content": f"Changed checkin interval to {check_in_every} seconds."}

    # set to around 10 minutes, depending on how often we're checking in
    encourage_every = round(check_in_every/60 * 10)

    temperature = 0.5

    data = json.loads(await websocket.receive_text())
    if data['type'] == 'register':
        print(f"registering user {data}")
        user = data['user']
        # plop into database
        c = app.state.db.cursor()
        c.execute("INSERT INTO users (username, fullname) VALUES (?, ?)", (user['username'], user['fullname']))
        app.state.db.commit()
        user_id = c.lastrowid
    else:
        raise ValueError(f"message type {data['type']} disallowed for first message")

    # after registration send a hardcoded initial message
    messages.append({"role": "assistant", "content": INITIAL_MESSAGE})
    await websocket.send_json({"type": "msg", **messages[-1]})


    last_check_in = 0
    while True:
        # TODO: Cleanup this mess. only here to make sure we don't miss any activities
        # by becoming stuck waiting for a title change.
        try:
            text = await asyncio.wait_for(websocket.receive_text(), timeout=5)
            data = json.loads(text)
            print('received', data)
        except asyncio.TimeoutError:
            if len(activity) > 0:
                # normally time.time() first but if the activity is fresh it's the same
                checked_last_time = activity[-1]['time'] - last_check_in > check_in_every and len(messages) > 3
                if not checked_last_time:
                    data = activity[-1]
                else:
                    continue

        if data['type'] == 'activity_info':
            # insert activity into database
            c = app.state.db.cursor()
            c.execute("INSERT INTO activity (user_id, app, window_title, time) VALUES (?, ?, ?, ?)", (user_id, data['app'], data['window_title'], data['time']))
            app.state.db.commit()
            activity.append(data)

            # don't do anything for undefined app/window title & our own window
            if not data['app'] or not data['window_title'] or data['app'].lower() == 'bossgpt':
                continue

            # len(messages) > 3 ensures the user has given some preference info,
            # and we've sent the reply to it. len(messages) = 2 to start.
            if time.time() - last_check_in > check_in_every and len(messages) > 3:
                last_check_in = time.time()

                # append most recent activity info to prompt
                # TODO: better prompting. this is pretty stupid
                messages.append({"role": "user", "content": f"I'm currently on app {data['app']} with title {data['window_title']}"})

                resp = await client.post(
                    "https://api.openai.com/v1/chat/completions",
                    json={
                        "model": "gpt-4",
                        "messages": distill_history(messages),
                        "max_tokens": 100,
                        "stop": ["Great work!"],
                        "temperature": temperature,
                    }
                )
                resp_data = resp.json()
                message = resp_data['choices'][0]['message']
                if message['content'].strip() == "":
                    message['content'] = "Great work!"
                print('chatgpt:', message['content'])
                should_reply = not (message['content'].startswith('Great work') and random.randint(0, int(encourage_every)) != 0)
                notif_opts = ["badge"] if message['content'].startswith('Great work') else ["alert", "sound"]

                if should_reply:
                    await websocket.send_text(json.dumps({"type": "msg", "notif_opts": notif_opts, **message}))
                    messages.append(message)

        elif data['type'] == 'msg': # reply to the user
            # save message  to db
            c = app.state.db.cursor()
            c.execute("INSERT INTO messages (user_id, content, role) VALUES (?, ?, ?)", (user_id, data['content'], data['role']))
            app.state.db.commit()

            messages.append({"role": "user", "content": data['content']})
            resp = await client.post(
                "https://api.openai.com/v1/chat/completions",
                json={
                    "model": "gpt-4",
                    "messages": distill_history(messages),
                    "temperature": temperature,
                    "functions": [
                        {
                            "name": "change_checkin",
                            "description": "Change how often you check the user's activity.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "new_interval": {
                                        "type": "integer",
                                        "description": f"The new time interval, in seconds, for checking activity. Current is {check_in_every}.",
                                    },
                                },
                                "required": ["new_interval"],
                            },
                        }
                    ],
                    "max_tokens": 100,
                }
            )
            resp_data = resp.json()
            message = resp_data['choices'][0]['message']
            if message.get("function_call"):
                available_functions = {
                    "change_checkin": change_checkin,
                }  # only one function in this example, but you can have multiple
                function_name = message["function_call"]["name"]
                fuction_to_call = available_functions[function_name]
                function_args = json.loads(message["function_call"]["arguments"])
                message = fuction_to_call(function_args['new_interval'])

            await websocket.send_text(json.dumps({"type": "msg", **message}))
            messages.append(message)



app.mount("/", StaticFiles(directory="static", html=True))
