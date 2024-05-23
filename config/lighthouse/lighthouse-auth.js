const puppeteer = require('puppeteer');
const {URL} = require('url');

async function run() {
  // Use Puppeteer to launch a browser and perform the login
  const browser = await puppeteer.launch({headless: true});
  const page = await browser.newPage();
  const testURL = 'https://' + process.env.APP_HOST_URL + '/login/index.php'
  const username = process.env.USERNAME; // Use the MOODLE_TESTER_USERNAME environment variable
  const password = process.env.PASSWORD; // Use the MOODLE_TESTER_PASSWORD environment variable

  await page.goto(testURL); // Use the APP_HOST_URL environment variable

  // Check that the username and password are set and are strings
  if (typeof username !== 'string' || typeof password !== 'string') {
    throw new Error('MOODLE_TESTER_USERNAME (' + username + ') and MOODLE_TESTER_PASSWORD must be set and must be strings');
  }

  await page.type('#username', username);
  await page.type('#password', password);
  await page.screenshot({path: 'before_click.png'}); // Take a screenshot before clicking the login button

  // Wait for both the click and navigation
  await Promise.all([
    page.click('#loginbtn'),
    page.waitForNavigation({timeout: 60000}),
  ]);

  await page.screenshot({path: 'after_click.png'}); // Take a screenshot after clicking the login button

  // Define the paths you want to navigate
  const paths = [
    '/course/view.php?id=60',
    '/mod/book/view.php?id=3078',
    '/mod/page/view.php?id=3079',
    '/course/view.php?id=60&section=2#module-3080',
    '/mod/url/view.php?id=3143'
  ];

  const pathCount = paths.length;
  let pathsPassed = 0;

  // Import Lighthouse
  const lighthouse = (await import('lighthouse')).default;

  // Loop over the paths and run Lighthouse on each one
  for (const path of paths) {
    const url = 'https://' + process.env.APP_HOST_URL + path;

    const {lhr} = await lighthouse(url, {
      port: (new URL(browser.wsEndpoint())).port,
      output: 'json',
      logLevel: 'info',
    });

    // Get the scores
    const accessibilityScore = lhr.categories.accessibility.score * 100;
    const performanceScore = lhr.categories.performance.score * 100;
    const bestPracticesScore = lhr.categories['best-practices'].score * 100;

    // Verify the scores
    if (accessibilityScore < 90) {
      throw new Error(`Accessibility score ${accessibilityScore} is less than 90 for ${path}`);
    }
    if (performanceScore < 40) {
      throw new Error(`Performance score ${performanceScore} is less than 40 for ${path}`);
    }
    if (bestPracticesScore < 80) {
      throw new Error(`Best Practices score ${bestPracticesScore} is less than 80 for ${path}`);
    }

    pathsPassed++;
  }

  console.log(`✔️ PASSED: All scores are above the minimum thresholds (${pathsPassed} of ${pathCount} urls passed)`);

  await browser.close();
}

run();
