const puppeteer = require('puppeteer');
const {URL} = require('url');

async function run() {
  // Use Puppeteer to launch a browser and perform the login
  const browser = await puppeteer.launch({headless: true});
  const page = await browser.newPage();
  const testURL = process.env.APP_HOST_URL + '/login/index.php'
  await page.goto(testURL); // Use the APP_HOST_URL environment variable
  await page.type('#username', process.env.MOODLE_TESTER_USERNAME); // Use the MOODLE_TESTER_USERNAME environment variable
  await page.type('#password', process.env.MOODLE_TESTER_PASSWORD); // Use the MOODLE_TESTER_PASSWORD environment variable
  await page.click('#loginbtn');
  await page.waitForNavigation();

  console.log('Logged in to ' + process.env.APP_HOST_URL);

  // Define the paths you want to navigate
  const paths = [
    '/course/view.php?id=60',
    '/mod/book/view.php?id=3078',
    '/mod/page/view.php?id=3079',
    '/course/view.php?id=60&section=2#module-3080',
    '/mod/url/view.php?id=3143'
  ];

  // Import Lighthouse
  const lighthouse = (await import('lighthouse')).default;

  // Loop over the paths and run Lighthouse on each one
  for (const path of paths) {
    const url = process.env.APP_HOST_URL + path;
    console.log(`Running Lighthouse on ${url}`);
    const {lhr} = await lighthouse(url, {
      port: (new URL(browser.wsEndpoint())).port,
      output: 'html',
      logLevel: 'info',
    });
    console.log(`Lighthouse score for ${path}: ${Object.values(lhr.categories).map(c => c.score).join(', ')}`);
  }

  await browser.close();
}

run();
