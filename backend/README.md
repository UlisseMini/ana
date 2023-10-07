## To run the backend:
`pip install -r requirements.txt` to install the requirements, make sure `uvicorn` is added to PATH, then run `uvicorn main:app` which should launch the server on `localhost:8000`. `OPENAI_API_KEY` is required.

## Stripe setup

Must have env vars: `STRIPE_API_KEY` (stripe secret key), `HOST` (URL to homepage of app for redirects)

For testing account & deployment account you need to do

```sh
stripe prices update price_1NsGBhIWzZPN3tivtQmsVYPD --lookup-key "bossgpt-standard"
```

In order to have lookup key right.

(TODO: It might be nice to have the whole stripe setup be cli-based, that way it's easy to transfer between stripe accounts.)
