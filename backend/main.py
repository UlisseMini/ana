from fastapi import FastAPI, Form, Request, HTTPException, Depends, WebSocket
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse
import sqlite3
import stripe
import os
import json
import asyncio
import httpx
import time
import random

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
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
                -- TODO add more fields for tracking activity

                FOREIGN KEY (user_id) REFERENCES users(id)
            );
        """)


@app.on_event("startup")
def startup():
    # TEMPORARY: delete db on startup for testing
    if os.path.exists("db.sqlite3"):
        os.remove("db.sqlite3")
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
- You are a productivity assistant. Every few minutes you will be asked to evaluate what the user is doing.
- If you don't know the user's preferences and motivations you should ask them.
- If the user is doing something they said they didn't want to do, you should ask them why they are doing it, and nicely try to motivate them to work.
- If they are on-task, you should encourage them without being distracting by saying "Great work!" in a short message with nothing else.
""".strip()




client = httpx.AsyncClient(headers={"Authorization": f"Bearer {OPENAI_API_KEY}"})

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    # TODO: These should all be stored in the database
    user = None # {"user_id": 1, ...}
    activity = [] # [{"type": "activity", "app": "ITerm", "window_title": "zsh", "time": <EPOCH>}]
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    check_in_every = 60
    def change_checkin(new_interval):
        nonlocal check_in_every
        check_in_every = new_interval
        print(f"changed checkin interval to {check_in_every}")

    encourage_every = 10

    # TODO: User registration (not needed for testing)
    # data = json.loads(await websocket.receive_text())
    # if data['type'] == 'register':
    #     print(f"registering user {data}")
    #     user = data['user']
    # else:
    #     raise ValueError(f"message type {data['type']} disallowed for first message")


    last_check_in = 0
    while True:
        data = json.loads(await websocket.receive_text())
        print('received', data)
        if data['type'] == 'activity_info':
            activity.append(data)
            if time.time() - last_check_in > check_in_every:
                last_check_in = time.time()

                # append most recent activity info to prompt
                # TODO: better prompting. this is pretty stupid
                messages.append({"role": "user", "content": f"The user is currently on {data['app']} doing {data['window_title']}"})

                resp = await client.post(
                    "https://api.openai.com/v1/chat/completions",
                    json={
                        "model": "gpt-3.5-turbo",
                        "messages": messages,
                        "max_tokens": 100,
                    }
                )
                resp_data = resp.json()
                message = resp_data['choices'][0]['message']
                print('chatgpt:', message['content'])
                should_reply = not (message['content'].startswith('Great work') and random.randint(0, int(encourage_every)) != 0)
                notif_opts = ["badge"] if message['content'].startswith('Great work') else ["alert", "sound"]

                if should_reply:
                    await websocket.send_text(json.dumps({"type": "msg", "notif_opts": notif_opts, **message}))

                    # don't pile up multiple assistant messages during checkins
                    # TODO: Should probably pile if the previous message wasn't a checkin
                    if messages[-1]['role'] != 'assistant':
                        messages.append(message)
                    else:
                        messages[-1] = message
                    print(messages)

        elif data['type'] == 'msg': # reply to the user
            messages.append({"role": "user", "content": data['content']})
            resp = await client.post(
                "https://api.openai.com/v1/chat/completions",
                json={
                    "model": "gpt-3.5-turbo",
                    "messages": messages,
                    "functions": [
                        {
                            "name": "change_checkin",
                            "description": "Change how often you check the user's activity. ",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "new_interval": {
                                        "type": "integer",
                                        "description": "The new time interval, in seconds, for checking activity. Default is 60.",
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
                fuction_to_call(function_args['new_interval'])
            else:
                await websocket.send_text(json.dumps({"type": "msg", **message}))
                messages.append(message)


        # TODO: Handle changing of check_in_every

        await asyncio.sleep(1)


app.mount("/", StaticFiles(directory="static", html=True))
