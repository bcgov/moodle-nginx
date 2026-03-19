const puppeteer = require('puppeteer');
const {URL} = require('url');
const testURL = process.env.APP_HOST_URL + '/login/index.php'

const options = {
  chromeFlags: ['--headless'],
  output: 'json'
};

async function retryNavigation(page, url, options = {}, maxRetries = 3) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      console.log(`Navigation attempt ${attempt} to: ${url}`);
      await page.goto(url, { waitUntil: 'networkidle0', timeout: 90000, ...options });
      console.log(`✅ Successfully navigated to: ${url}`);
      return;
    } catch (error) {
      console.log(`❌ Navigation attempt ${attempt} failed for: ${url}`);
      console.log(`Error: ${error.message}`);

      if (attempt === maxRetries) {
        console.log(`🚫 All navigation attempts failed for: ${url}`);
        throw new Error(`Failed to navigate to ${url} after ${maxRetries} attempts. Last error: ${error.message}`);
      }

      // Wait before retrying (exponential backoff)
      const waitTime = Math.pow(2, attempt) * 1000;
      console.log(`⏳ Waiting ${waitTime}ms before retry...`);
      await new Promise(resolve => setTimeout(resolve, waitTime));
    }
  }
}

async function waitForSiteReadiness(page, url, maxWaitTime = 300000) {
  console.log(`🔍 Checking site readiness for: ${url}`);
  const startTime = Date.now();

  while (Date.now() - startTime < maxWaitTime) {
    try {
      const response = await page.goto(url, {
        waitUntil: 'domcontentloaded',
        timeout: 30000
      });

      if (response && response.status() === 200) {
        console.log(`✅ Site is ready! Status: ${response.status()}`);
        return true;
      } else {
        console.log(`⚠️ Site returned status: ${response ? response.status() : 'no response'}`);
      }
    } catch (error) {
      console.log(`⚠️ Site not ready yet: ${error.message}`);
    }

    console.log(`⏳ Waiting 10 seconds before next readiness check...`);
    await new Promise(resolve => setTimeout(resolve, 10000));
  }

  throw new Error(`Site was not ready within ${maxWaitTime / 1000} seconds`);
}

async function getDynamicPaths(page, baseUrl, maxPages = 5) {
  const paths = [];

  // 1. Go to "my/courses.php"
  await retryNavigation(page, `${baseUrl}/my/courses.php`);

  // Wait for course cards/list to render. Moodle themes vary in markup and can
  // load sections after initial navigation settles.
  await page.waitForSelector('body', { timeout: 30000 });
  await page.waitForFunction(() => document.readyState === 'complete', { timeout: 30000 });
  await page
    .waitForFunction(
      () =>
        document.querySelectorAll('a[href*="/course/view.php?id="]').length > 0 ||
        document.body.innerText.includes('No courses') ||
        document.body.innerText.includes('No courses found'),
      { timeout: 20000 }
    )
    .catch(() => null);

  // 2. Find the first course link
  const courseLinks = await page.evaluate(() => {
    const selectors = [
      '.course-info-container a[href*="/course/view.php?id="]',
      '.coursename a[href*="/course/view.php?id="]',
      '.coursebox a[href*="/course/view.php?id="]',
      'a.aalink.coursename[href*="/course/view.php?id="]',
      'a[href*="/course/view.php?id="]'
    ];
    const hrefs = selectors
      .flatMap(selector => Array.from(document.querySelectorAll(selector)))
      .map(a => a.getAttribute('href'))
      .filter(Boolean);

    return Array.from(new Set(hrefs));
  });
  if (courseLinks.length === 0) {
    const pageText = await page.evaluate(() => document.body.innerText.slice(0, 600));
    throw new Error(`No courses found for user. Debug page text: ${pageText}`);
  }

  // Use the first course
  const courseUrl = courseLinks[0].startsWith('http') ? courseLinks[0] : baseUrl + courseLinks[0];
  paths.push(new URL(courseUrl).pathname + new URL(courseUrl).search);

  // 3. Go to the course page
  await retryNavigation(page, courseUrl);

  // 4. Find up to 5 resource/page links
  const pageLinks = await page.$$eval(
    'a.courseindex-link',
    (links, maxPages) =>
      links
        .map(a => a.getAttribute('href'))
        .filter(href => href && href.includes('/mod/page/view.php?id='))
        .slice(0, maxPages),
    maxPages
  );
  for (const link of pageLinks) {
    const fullUrl = link.startsWith('http') ? link : baseUrl + link;
    paths.push(new URL(fullUrl).pathname + new URL(fullUrl).search);
  }

  return paths;
}

async function runLighthouse(url, options, config = null) {
  // Import chrome-launcher
  const detectEncodingIssues = ['â', '€', '™', 'Â', 'œ', ''];
  let errors = new Array();
  let warnings = new Array();
  const { launch } = await import('chrome-launcher');

  // Launch a new Chrome instance
  const chrome = await launch({chromeFlags: ['--headless']});
  options.port = chrome.port;

  const sanitizeInput = (str) => {
    return str.replace(/[\n\r\t]/g, "");
  }

  function containsControlCharacters(str) {
    return /[\b\f\n\r\t\v]/.test(str);
  }

  // Use Puppeteer to launch a browser and perform the login
  const browser = await puppeteer.launch({
    headless: true,
    browserURL: `http://127.0.0.1:${chrome.port}`
  });
  const page = await browser.newPage();
  const username = sanitizeInput(process.env.USERNAME); // Use the MOODLE_TESTER_USERNAME environment variable
  const password = sanitizeInput(process.env.PASSWORD); // Use the MOODLE_TESTER_PASSWORD environment variable

  // Import Lighthouse
  const lighthouse = (await import('lighthouse')).default;
  const fs = (await import('fs')).default;
  const fsp = (await import('fs')).promises;

  // Wait for site to be ready before starting tests
  await waitForSiteReadiness(page, url);

  await retryNavigation(page, url); // Use the APP_HOST_URL environment variable

  // Check that the username and password are set and are strings
  if (typeof username !== 'string' || typeof password !== 'string') {
    throw new Error('MOODLE_TESTER_USERNAME (' + username + ') and MOODLE_TESTER_PASSWORD must be set and must be strings');
  }

  await page.screenshot({path: 'before_login_1_open.png'}); // Take a screenshot before clicking the login button
  const content = await page.content();
  await fsp.writeFile('before_login.html', content);

  try {
    // Wait for the login button to be available
    await page.waitForSelector('.loginform', { timeout: 30000 });

    // Click the link to open the form
    await page.click('.loginform>details summary');

    // Wait for the login button to be available and visible
    await page.waitForSelector('#loginbtn', { visible: true, timeout: 30000 });

    // Ensure the login button is visible and scroll it into view
    await page.evaluate(() => {
      const loginButton = document.querySelector('#loginbtn');
      if (loginButton) {
        loginButton.scrollIntoView();
      }
    });

    // Check if the username field exists
    const usernameField = await page.$('#username');
    if (!usernameField) {
      throw new Error('No element found for selector: #username');
    }
    // Enter the username
    await usernameField.type(username);

    // Check if the password field exists
    const passwordField = await page.$('#password');
    if (!passwordField) {
      throw new Error('No element found for selector: #password');
    }
    // Enter the password
    await page.type('#password', password);

    await page.screenshot({path: 'before_login_2_click.png'}); // Take a screenshot before clicking the login button

    // Wait for both the click and navigation
    await Promise.all([
      page.click('#loginbtn'),
      page.waitForNavigation({ timeout: 90000 }),
    ]);
  } catch (error) {
    console.error('❌ Login process failed:');
    console.error(`Error: ${error.message}`);
    console.error(`URL: ${url}`);

    // Take a diagnostic screenshot
    try {
      await page.screenshot({path: 'login_error_debug.png', fullPage: true});
      console.log('📸 Debug screenshot saved as login_error_debug.png');
    } catch (screenshotError) {
      console.error('Failed to take debug screenshot:', screenshotError.message);
    }

    // Log page content for debugging
    try {
      const currentContent = await page.content();
      await require('fs').promises.writeFile('login_error_debug.html', currentContent);
      console.log('📄 Debug HTML saved as login_error_debug.html');
    } catch (contentError) {
      console.error('Failed to save debug HTML:', contentError.message);
    }

    console.error('Login button not found or not clickable within timeout period.');
    process.exit(1); // Fail the test
  }

  for (const char of detectEncodingIssues) {
    if (content.includes(char)) {
      errors.push(`Found improperly encoded character "${char}" in the HTML content of: ${path}`);
      // throw new Error(`Found improperly encoded character "${char}" in the HTML content`);
    }
  }

  await page.screenshot({path: 'after_login_click.png'}); // Take a screenshot after clicking the login button

  // After login, generate dynamic paths
  // This provides comprehensive coverage of different page types:
  // - Login page: Authentication, session management
  // - Courses list: Database queries, user permissions
  // - Course view (2x): Content rendering + cache performance validation
  // - Module pages: Activity plugins, resource delivery, anomaly detection
  const baseUrl = process.env.APP_HOST_URL;
  const numberOfPages = 5; // Balance between coverage and execution time (~4-6 min)
  const paths = await getDynamicPaths(page, baseUrl, numberOfPages);
  const pathCount = paths.length;
  let pathsPassed = 0;
  let pathsFailed = 0;
  let results = [];

  // Loop over the paths and run Lighthouse on each one
  for (const path of paths) {
    const url = process.env.APP_HOST_URL + path;
    // await page.setCookie(...cookies);
    const {lhr} = await lighthouse(url, options, config);
    await retryNavigation(page, url); // Navigate to the new URL

    // Get the scores
    const accessibilityScore = lhr.categories.accessibility.score * 100;
    const performanceScore = lhr.categories.performance.score * 100;
    const bestPracticesScore = lhr.categories['best-practices'].score * 100;
    const filename = pathsPassed.toString() + '_' + path.replace(/\W+/g, "_");

    const pageContent = await page.content();
    await fsp.writeFile(filename + '.html', content);
    await page.screenshot({path: filename + '.png'}); // Take a screenshot after clicking the login button

    // Verify the scores
    if (accessibilityScore < 90) {
      errors.push(`❌ Accessibility score ${accessibilityScore} is less than 90 for ${path}`);
      pathsFailed++;
      // throw new Error(`Accessibility score ${accessibilityScore} is less than 90 for ${path}`);
    }
    if (performanceScore < 35) {
      errors.push(`❌ Performance score ${performanceScore} is less than 35 for ${path}`);
      pathsFailed++;
      // throw new Error(`Performance score ${performanceScore} is less than 35 for ${path}`);
    }
    if (bestPracticesScore < 80) {
      errors.push(`❌ Best Practices score ${bestPracticesScore} is less than 80 for ${path}`);
      pathsFailed++;
      // throw new Error(`Best Practices score ${bestPracticesScore} is less than 80 for ${path}`);
    }

    for (const char of detectEncodingIssues) {
      if (pageContent.includes(char)) {
        warnings.push(`⚠️ Character encoding issue detected on: ${path}`);
        // throw new Error(`⚠️ Found improperly encoded character "${char}" in the HTML content`);
      }
    }

    // Add the scores to the results array
    results.push({
      path,
      accessibilityScore,
      performanceScore,
      bestPracticesScore
    });

    pathsPassed++;
  }

  await browser.close();
  await chrome.kill();

  // Write the results to a JSON file:
  fs.writeFileSync('lighthouse-results.json', JSON.stringify(results));
  // Convert the results to a markdown table
  let markdown = '| Path | Accessibility Score | Performance Score | Best Practices Score |\n|------|---------------------|-------------------|----------------------|\n';
  for (const result of results) {
    markdown += `| ${result.path} | ${result.accessibilityScore} | ${result.performanceScore} | ${result.bestPracticesScore} |\n`;
  }
  // Write the markdown to a file
  fs.writeFileSync('lighthouse-results.md', markdown);

  let warningString = '';
  if (warnings.length > 0) {
    if (warningString == '') {
      warningString += ' - Warnings: ';
    }
    for (const warning of warnings) {
      warningString += ' - ' + warning;
    }
  }

  if (errors.length > 0) {
    let errorString = '';
    for (const error of errors) {
      errorString += ' - ' + error;
    }
    console.log(`❌ **FAILED**: Some scores (${errors.length}) are below the minimum thresholds (${pathsFailed} of ${pathCount} urls failed) - Errors: ${errorString} ${warningString}`);
  } else {
    console.log(`✔️ **PASSED**: All scores are above the minimum thresholds (${pathsPassed} of ${pathCount} urls passed) ${warningString}`);
  }
}

async function runTests() {
  const report = await runLighthouse(testURL, options);
}

runTests();
