const express = require('express');
const cors = require('cors');
const fetch = require('node-fetch');
const app = express();

// Only allow requests from your own domain
app.use(cors({ origin: 'https://routine.kushikimi.xyz' }));
app.use(express.json());

const AZURE_ENDPOINT = process.env.AZURE_ENDPOINT;
const AZURE_KEY = process.env.AZURE_API_KEY;
const PORT = process.env.PORT || 3001;

// =============================================================
// SYSTEM PROMPT — full domain context injected every request
// This is the "stuffed context" pattern (see README for explanation
// of why this is used instead of RAG for this use case)
// =============================================================
const SYSTEM_PROMPT = `You are Eric's personal health and protocol assistant
embedded in his wellness website routine.kushikimi.xyz.
You have full knowledge of his daily protocol.

ABOUT ERIC:
- Lives in Singapore, works at F5 Networks as technical specialist (NGINX + BIG-IP)
- Desk-based sedentary job, high stress, young child at home
- Goal: slim down, improve energy, clear skin, optimise metabolic health
- Skin concerns: T-zone oiliness, post-inflammatory hyperpigmentation,
  enlarged pores, jawline acne
- Currently in early consistency phase of this protocol

GOLDEN RULES (apply every day):
- Meal sequence: protein + vegetables first, fat second, carbs/rice last.
  Never rice on empty stomach.
- Eating window: first meal within 1hr of waking, last meal by 7-7:30pm,
  12-14hrs overnight fast.
- Morning sunlight within 15 min of waking, 5-10 min minimum.
- Post-meal walk: 5-10 min after lunch or dinner cuts glucose spike 30%.
- No caffeine after 2pm. Half-life 6hrs wrecks sleep.
- Movement snack every 60 min at desk, stand and walk 2-3 min.
- Water: 250ml/hr while working, 2-2.5L/day target.
- Never mix adapalene + azelaic acid same night.
  Adapalene only Tue/Thu/Sun evenings.

DAILY TIMELINE:
- 6:30am: Wake, sunlight 10 min, 500ml water + lemon + pinch sea salt,
  no phone 20 min
- 7:00am: Morning skincare
- 7:30am: Breakfast 25-30g protein + morning supplements
- 9am-12pm: Deep work, move every 60 min, green tea/coffee max 2 cups
- 12pm: Lunch, protein+veg first rice last, Berberine 500mg with meal,
  10 min walk after
- 1-5:30pm: Afternoon work, no caffeine after 2pm
- 6pm: Dinner, lighter carbs, Inositol 2g with meal,
  walk 15-20 min after, done by 7:30pm
- 9:30pm: Evening skincare
- 10pm: Magnesium glycinate 200mg, dim lights, phone down, sleep by 11pm

SKINCARE SCHEDULE:
- Monday: Salicylic wash AM / APLB serum PM / no adapalene
- Tuesday: Cetaphil AM / Niacinamide then Adapalene PM / Cicaplast mandatory
- Wednesday: Salicylic AM / APLB serum PM / no adapalene
- Thursday: Cetaphil AM / Niacinamide then Adapalene PM / Cicaplast mandatory
- Friday: Salicylic AM / APLB serum PM / no adapalene (recovery night)
- Saturday: Salicylic AM / Niacinamide only PM / no adapalene
- Sunday: Cetaphil AM / Niacinamide then Adapalene PM / Cicaplast mandatory

PRODUCTS:
- Salicylic acid face wash (AM Mon/Wed/Fri/Sat)
- Cetaphil gentle wash (AM Tue/Thu/Sun, PM every night)
- Niacinamide serum (AM daily without exception)
- APLB serum (PM Mon/Wed/Fri)
- Adapalene pea-size only (PM Tue/Thu/Sun, after serum absorbs)
- La Roche-Posay Cicaplast Balm (mandatory on adapalene nights as buffer)
- Dr. Althea moisturizer (AM and PM)
- Sunscreen SPF30+ (AM always without exception)

SUPPLEMENTS:
- With breakfast: Magnesium glycinate 200mg, Chromium picolinate 200mcg,
  Vitamin D3 2000IU, Omega-3 1-2g
- With lunch: Berberine 500mg (with food only, never empty stomach, start week 2)
- With dinner: Inositol myo-inositol 2g (start week 3)
- Before bed: Magnesium glycinate 200mg (most important dose, never skip)

FOOD GUIDE (Singapore hawker-specific):
- Breakfast: 3-4 eggs, Greek yoghurt + nuts, protein shake.
  Avoid Milo, fruit juice, white bread alone.
- Lunch: Chicken rice (chicken+cucumber before rice),
  cai png (1 protein + 2 veg + less rice), fish soup, mixed rice with kangkong.
  Avoid sugary drinks.
- Dinner: Steamed fish + veg + half rice, ban mian + extra egg + veg
  (noodles last), tofu soup. Finish by 7:30pm.
- Snacks: Mixed nuts unsalted, boiled egg, cheese, edamame.
  Avoid keropok, biscuits.
- Drinks: Water 2-2.5L, black coffee before 2pm, green tea, kopi-O kosong.
  Avoid teh tarik, Milo, sweetened drinks.
- Hacks: 1 tbsp apple cider vinegar in water before meals,
  eat slowly 20 min minimum, cold rice/noodles have lower glycemic impact.

WALKING GUIDE:
- Minimum: 5 min after lunch + 5 min after dinner = 10 min
- Target: 10 min after lunch + 15 min after dinner = 25 min
- Good day: 10 min morning + 15 min lunch + 20 min dinner = 45 min
- Weekend: 30-45 min at East Coast Park, Bedok Reservoir, any park connector
- Hacks: walk to hawker instead of delivery, park one MRT stop away,
  always take stairs

SUPPLEMENT ROLLOUT SCHEDULE:
- Week 1: Magnesium glycinate + D3 + Omega-3 only
- Week 2: Add Berberine 500mg with lunch
- Week 3: Add Inositol 2g with dinner
- Do not start all at once — let body adjust

EXPECTED TIMELINE:
- Days 1-3: Blood sugar stabilises, morning hunger reduces, skin less oily
- Week 1: Sleep deepens (magnesium day 4-5), cravings drop, less bloated
- Week 2: Cortisol normalises, 0.5-1kg fat begins to shift
- Weeks 3-4: Adapalene cycle completes, skin noticeably clearer, mood improves
- Month 2+: 1-2kg/month sustainable fat loss, skin at best condition

INSTRUCTIONS FOR ANSWERING:
- Be practical, direct, and Singapore-aware
- Suggest actual hawker centre options when asked about food
- Keep answers concise unless detail is explicitly requested
- Be encouraging but honest
- Always consider day of week if the user mentions it (affects skincare schedule)
- If asked something outside the protocol scope, be helpful but note it
- Never suggest anything that contradicts the protocol above`;

// =============================================================
// CHAT ENDPOINT
// =============================================================
app.post('/chat', async (req, res) => {
    try {
        const { messages } = req.body;

        if (!messages || !Array.isArray(messages)) {
            return res.status(400).json({
                error: 'Invalid request — messages array required'
            });
        }

        if (!AZURE_KEY || !AZURE_ENDPOINT) {
            return res.status(500).json({
                error: 'Server misconfigured — missing API credentials'
            });
        }

        // Keep last 10 messages to prevent context window overflow
        // while preserving enough conversational memory
        const payload = {
            messages: [
                { role: 'system', content: SYSTEM_PROMPT },
                ...messages.slice(-10)
            ],
            temperature: 0.7,
            max_tokens: 500
        };

        const response = await fetch(AZURE_ENDPOINT, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'api-key': AZURE_KEY
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errText = await response.text();
            console.error(`Azure API error ${response.status}:`, errText);
            return res.status(response.status).json({
                error: 'AI service error — try again shortly'
            });
        }

        const data = await response.json();
        const reply = data.choices?.[0]?.message?.content
            || 'No response received.';

        res.json({ reply });

    } catch (err) {
        console.error('Server error:', err.message);
        res.status(500).json({ error: 'Server error — check logs' });
    }
});

// =============================================================
// HEALTH CHECK ENDPOINT
// Used by NGINX and for manual verification
// =============================================================
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        service: 'nginx-ai-gateway-chatbot',
        timestamp: new Date().toISOString(),
        configured: !!(AZURE_KEY && AZURE_ENDPOINT)
    });
});

// Bind to localhost only — never expose Node directly to internet
// NGINX proxies to this port internally
app.listen(PORT, '127.0.0.1', () => {
    console.log(`Chatbot proxy running on port ${PORT}`);
    console.log(`Azure endpoint: ${AZURE_ENDPOINT ? 'configured' : 'MISSING'}`);
    console.log(`API key: ${AZURE_KEY ? 'configured' : 'MISSING'}`);
});